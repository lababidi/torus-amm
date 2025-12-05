// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {console} from "forge-std/console.sol";

interface IPermit2 {
    function allowance(address from, address to) external view returns (uint256);

    function transferFrom(address from, address to, uint256 amount, address token) external;
}

contract TorusVault is ERC4626 {
    Torus public torus;
    using SafeERC20 for IERC20;

    IERC20 private _asset;

    constructor(address underlying, string memory name, string memory symbol)
        ERC4626(IERC20(underlying))
        ERC20(name, symbol)
    {
        torus = Torus(msg.sender);
        // Additional initialization if needed
    }

    function hold(uint256 amount) external {
        require(msg.sender == address(torus), "Only Torus can call hold");
        _asset.safeTransferFrom(msg.sender, address(this), amount);
    }

    function borrow(uint256 amount) external {
        require(msg.sender == address(torus), "Only Torus can call borrow");
        _asset.safeTransferFrom(address(this), msg.sender, amount);
    }
}

contract Torus {
    struct Token {
        address adr;
        uint8 decimals;
        string name;
        string symol;
    }

    struct TokenStatus {
        Token token;
        bool surpassed;
        uint256 liquidity;
        uint256 reserves;
        TorusVault vault;
        uint256 fees;
    }

    using SafeERC20 for IERC20;

    uint24 public n;
    uint256[] public r; // global invariants - one for each slice in the tower of AMMs
    mapping(address => uint16) public pos; // position of token in tokens array

    Token[] public tokens;
    TokenStatus[][] public status;
    uint256[] public ticks; //not ordered
    mapping(address => bool) public supported;
    mapping(uint256 => bool) public validTicks;
    mapping(address => bool) public activeVaults;
    address[] public activeTokens;
    uint256[] public liquidityBase; // minimum liquidity across all tokens for each tick

    IPermit2 public constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    modifier vaultOnly(address vault) {
        require(activeVaults[vault], "Only vault can call this function");
        _;
    }

    modifier validTick(uint16 tickid) {
        require(tickid < ticks.length, "Invalid tick id");
        _;
    }

    modifier validToken(address token) {
        require(token != address(0), "Invalid token address");
        require(supported[token], "Token not supported");
        _;
    }

    modifier validTokens(address token1, address token2) {
        require(token1 != address(0), "Invalid token address");
        require(supported[token1], "Token not supported");
        require(token2 != address(0), "Invalid token address");
        require(supported[token2], "Token not supported");
        _;
    }


    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    address public owner;

    constructor(address tokenA, address tokenB, uint256 tick) {
        owner = msg.sender;
        ticks.push(tick);
        addToken(tokenA);
        addToken(tokenB);
        // status[0][0].vault.deposit(100, msg.sender);
        // status[0][1].vault.deposit(100, msg.sender);
    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        if(IERC20(token).allowance(from, to) > amount){
            IERC20(token).safeTransferFrom(from, to, amount);
        } else if (PERMIT2.allowance(from, to) > amount){
            PERMIT2.transferFrom(from, to, amount, token);
        } else {
            revert("Insufficient allowance");
        }
    }

    function createVault(Token memory token, uint256 tickValue) internal returns (TorusVault) {
        TorusVault vaultToken = new TorusVault(
            token.adr,
            string(abi.encodePacked("Torus ", token.name)),
            string(abi.encodePacked("trs-", token.symol, tickValue))
        );
        return vaultToken;
    }


    function addToken(address token) public onlyOwner {
        require(token != address(0), "Invalid token address");
        require(ticks.length > 0, "No Ticks defined");
        
        supported[token] = true;
        pos[token] = uint16(n);
        n += 1;

        Token memory tokenInfo = Token({
            adr: token,
            decimals: uint8(IERC20Metadata(token).decimals()),
            name: IERC20Metadata(token).name(),
            symol: IERC20Metadata(token).symbol()
        });

        for (uint256 i = 0; i < ticks.length; i++) {
            status[i].push(
                TokenStatus({
                    token: tokenInfo,
                    surpassed: false,
                    liquidity: 0,
                    reserves: 0,
                    vault: createVault(tokenInfo, ticks[i]),
                    fees: 0
                })
            );
        }
        tokens.push(tokenInfo);
    }


    function addTick(uint256 tickValue) public onlyOwner {
        ticks.push(tickValue);
        status.push();
        for (uint256 i = 0; i < tokens.length; i++) {
            status[ticks.length - 1].push(
                TokenStatus({
                    token: tokens[i],
                    surpassed: false,
                    liquidity: 0,
                    reserves: 0,
                    vault: createVault(tokens[i], tickValue),
                    fees: 0
                })
            );
        }
    }



    // Called by the vault to modify liquidity
    function updateLiquidity(address token, int256 amount, uint16 tickid) 
        public validToken(token) validTick(tickid) vaultOnly(msg.sender) {
        uint16 i = pos[token];
        int256 liq = tokenToCurrency(amount, tokens[i].decimals);
        TokenStatus storage ts = status[tickid][i];
        int256 prev = int256(ts.liquidity);
        int256 prevRes = int256(ts.reserves);

        ts.liquidity = uint256(prev + liq);
        ts.reserves = uint256(prevRes + liq);
        // Update minSurpassed
        if (!ts.surpassed && ts.liquidity >= 1000e18) {
            ts.surpassed = true;
            // out of minSurpassed find smallest Liquidity
            for (uint16 t = 0; t < ticks.length; t++) {
                uint256 minLiq = type(uint256).max;
                for (uint16 j = 0; j < tokens.length; j++) {
                    TokenStatus storage st = status[t][j];
                    if (st.surpassed && st.liquidity < minLiq) {
                        minLiq = st.liquidity;
                    }
                }
                liquidityBase[t] = minLiq;
            }
        }
    }


    function getSwapAmount(
        uint256 amountIn
        // int256 ai,
        // int256 ao,
        // uint256 liqIn,
        // uint256 liqOut,
        // uint256 xi,
        // uint256 xo
    ) public pure returns (int256 amountOut) {
        amountOut = int256(amountIn); // Placeholder logic
    }


    function swap(address tokenOut, address tokenIn, uint256 swapAmountIn, address to)
        public validToken(tokenOut) validToken(tokenIn) {

        uint16 i = pos[tokenIn];
        uint16 j = pos[tokenOut];
        uint256 amountIn = tokenToCurrency(swapAmountIn, tokens[i].decimals);
        uint256 amountOut = uint256(getSwapAmount(amountIn));
        uint256 swapAmountOut = currencyToToken(amountOut, tokens[j].decimals);

        _transferFrom(tokenIn, msg.sender, address(this), swapAmountIn);
        status[0][i].vault.hold(swapAmountIn);
        status[0][i].liquidity += amountIn;
        status[0][i].reserves += amountIn;
        
        status[0][j].liquidity -= amountOut;
        status[0][j].reserves -= amountOut;
        status[0][j].vault.borrow(swapAmountOut);
        _transferFrom(tokenOut, address(this), to, swapAmountOut);
        // vault.borrow()
        // vault.tempdeposit(amountIn, msg.sender);
    }

    function swap(address tokenOut, address tokenIn, uint256 amountIn)
        public validToken(tokenOut) validToken(tokenIn) {
        swap(tokenOut, tokenIn, amountIn, msg.sender);
    }







    function totalLiquidity(address token) public view returns (uint256 totalLiq) {
        uint16 i = pos[token];
        for (uint16 tickid = 0; tickid < ticks.length; tickid++) {
            totalLiq += status[tickid][i].liquidity;
        }
    }


    function totalReserves(address token) public view returns (uint256 totalRes) {
        uint16 i = pos[token];
        for (uint16 tickid = 0; tickid < ticks.length; tickid++) {
            totalRes += status[tickid][i].reserves;
        }
    }

    // Price between tokenA and tokenB depends on the ratio of [(a-x)/a] /[(b-y)/b].
    // This is from the partial derivative of the invariant function.
    function getPrice(address tokenA, address tokenB)
        public
        view
        validToken(tokenA)
        validToken(tokenB)
        returns (int256)
    {
        uint16 i = pos[tokenA];
        uint16 j = pos[tokenB];
        int256 al = div(int256(r[i]), int256(totalLiquidity(tokenA)));
        int256 bl = div(int256(r[j]), int256(totalLiquidity(tokenB)));

        return div(mul(al, (1e18 - mul(al, int256(totalReserves(tokenA))))) , mul(bl, (1e18 - mul(bl, int256(totalReserves(tokenB))))));
    }



    function tokenToCurrency(uint256 amount, uint16 decimal) internal pure returns (uint256 liq) {
        if (18 > decimal) {
            liq = amount * (10 ** uint16(18 - decimal));
        } else if (18 < decimal) {
            liq = amount / (10 ** uint16(decimal - 18));
        } else {
            liq = amount;
        }
    }

    function currencyToToken(uint256 liq, uint16 decimal) internal pure returns (uint256 amount) {
        if (18 > decimal) {
            amount = liq / (10 ** uint16(18 - decimal));
        } else if (18 < decimal) {
            amount = liq * (10 ** uint16(decimal - 18));
        } else {
            amount = liq;
        }
    }

    function tokenToCurrency(int256 amount, uint16 decimal) internal pure returns (int256 liq) {
        if (18 > decimal) {
            liq = amount * int256(10 ** (18 - decimal));
        } else if (18 < decimal) {
            liq = amount / int256(10 ** (decimal - 18));
        } else {
            liq = amount;
        }
    }

    function currencyToToken(int256 liq, uint16 decimal) internal pure returns (int256 amount) {
        if (18 > decimal) {
            amount = liq / int256(10 ** (18 - decimal));
        } else if (18 < decimal) {
            amount = liq * int256(10 ** (decimal - 18));
        } else {
            amount = liq;
        }
    }


    function sq(uint256 x_) internal pure returns (uint256) {
        return mul(x_, x_);
    }

    function sq(int256 x_) internal pure returns (int256) {
        return mul(x_, x_);
    }

    function cube(int256 x_) internal pure returns (int256) {
        return mul(x_, sq(x_));
    }

    function muldiv(uint256 x_, uint256 y_, uint256 z_) internal pure returns (uint256) {
        return (x_ * y_) / z_;
    }

    function muldiv(uint256 x_, int256 y_, uint256 z_) internal pure returns (int256) {
        return (int256(x_) * y_) / int256(z_);
    }

    function muldiv(uint256 x_, uint256 y_, int256 z_) internal pure returns (int256) {
        return (int256(x_) * int256(y_)) / z_;
    }

    function mul(uint256 x_, uint256 y_) internal pure returns (uint256) {
        return (x_ * y_) / 1e18;
    }

    function mul(int256 x_, int256 y_) internal pure returns (int256) {
        return (x_ * y_) / 1e18;
    }

    function mul2(uint256 x_, uint256 y_) internal pure returns (uint256) {
        return (x_ * y_) / 1e36;
    }

    function div(uint256 x_, uint256 y_) internal pure returns (uint256) {
        return (x_ * 1e18) / y_;
    }

    function div(int256 x_, int256 y_) internal pure returns (int256) {
        return (x_ * 1e18) / y_;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        y = y * 1e18;
        if (y > 3) {
            z = y;
            uint256 x_ = y / 2 + 1;
            while (x_ < z) {
                z = x_;
                x_ = (y / x_ + x_) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function sqrt2(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x_ = y / 2 + 1;
            while (x_ < z) {
                z = x_;
                x_ = (y / x_ + x_) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function abs_(int256 x_) internal pure returns (uint256) {
        return uint256(x_ >= 0 ? x_ : -x_);
    }

    function abs(int256 x_) internal pure returns (int256) {
        return int256(x_ >= 0 ? x_ : -x_);
    }

    function sub(uint256 x_, int256 y_) internal pure returns (uint256) {
        require(y_ >= 0 ? x_ >= uint256(y_) : true, "Underflow in subtraction");
        return x_ >= uint256(y_) ? x_ - uint256(y_) : 0;
    }
    function boolpm(bool b) internal pure returns (int8) {
        return b ? int8(1) : int8(-1);
    }

    function incdec(bool inc, uint16 i) internal pure returns (uint16) {
        return inc ? i + 1 : i - 1;
    }

}
