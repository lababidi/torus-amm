// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {console} from "forge-std/console.sol";

contract TorusRedemption is ERC4626 {
    Torus public torus;
    constructor(address underlying, string memory name, string memory symbol)
        ERC4626(IERC20(underlying))
        ERC20(name, symbol)
    {
        torus = Torus(msg.sender);
        // Additional initialization if needed
    }

}

contract Torus {
    using SafeERC20 for IERC20;
    uint24 public n;
    uint256 public lsum;
    uint256 public lmax;
    mapping(address => uint16) public pos; // position of token in tokens array
    address[] public tokens;
    uint16[] public order;
    uint256[] public liquidity;
    uint256[] public minLiquidity;
    uint16[] public decimals;
    uint256[] public liquidityNorm;
    uint256[] public x;
    uint256[] public a;
    uint256[] public fees;
    address[] public redemption;
    uint16[] public redemptionPos;
    mapping(address => bool) public supported;
    mapping(address => bool) public minSurpassed;


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
    modifier liquidToken(address token) {
        require(token != address(0), "Invalid token address");
        require(supported[token], "Token not supported");
        require(minSurpassed[token], "Minimum liquidity not surpassed");
        _;
    }
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    address public owner;

    constructor(address tokenA, address tokenB) {
        owner = msg.sender;
        addToken(tokenA);
        addToken(tokenB);
        // initLiquidity(100);

    }
    function initLiquidity(uint256 liq) public  {
        for (uint16 i = 0; i < 2; i++) {
            address token = tokens[i];
            uint256 amount = calcTransfer(liq, decimals[i]);
            liquidity[i] = liq;
            x[i] = liq;
            bubble(i, false);
            updateTotal();
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            // mint redemption tokens todo
        }

        calculateA();
    }
    function getTokens() public view returns (address[] memory activeTokens) {
        activeTokens = new address[](tokens.length);
        uint256 count = 0;
        for (uint i = 0; i < tokens.length; i++) {
            if (supported[tokens[i]] && minSurpassed[tokens[i]]) {
                activeTokens[count] = tokens[i];
                count++;
            }
        }
        // Resize the array to the number of active tokens
        assembly {
            mstore(activeTokens, count)
        }
    }

    function boolpm(bool b) internal pure returns (int8) {
        return b ? int8(1) : int8(-1);
    }

    function incdec(bool inc, uint16 i) internal pure returns (uint16) {
        return inc ? i + 1 : i - 1;
    }

    function _bubbleUp(uint16 idx) internal {
        // Move element at idx toward the front while it outranks its predecessor
        uint16 current = idx;
        uint16 end = 0;
        while (current > end) {
            uint16 i = order[current];
            uint16 j = order[current - 1];

            if (liquidity[i] <= liquidity[j]) break;

            // swap a <-> b
            order[current]     = j;
            order[current - 1] = i;

            unchecked { current=incdec(false, current); }
        }
        lmax = liquidity[order[0]];
    }

    function bubble(uint16 idx, bool down) internal {
        uint16 current = down ? idx + 1 : idx;
        uint16 end = down? uint16(order.length):0;
        while (current  < end) {
            uint16 i = order[current];
            uint16 j = order[current-1];
            if (liquidity[i] <= liquidity[j]) break;
            order[current]   = j;  // swap a <-> b
            order[current-1] = i;
            unchecked { current=incdec(down, current); }
        }
        lmax = liquidity[order[0]];
    }

    function setMinLiquidity(address token, uint256 min) public onlyOwner validToken(token) {
        minLiquidity[pos[token]] = min;
    }

    function addToken(address token) public onlyOwner {
        require(token != address(0), "Invalid token address");
        supported[token] = true;
        tokens.push(token);
        n += 1;
        pos[token] = uint16(n - 1);
        order.push(uint16(n - 1));
        liquidity.push(0);
        minLiquidity.push(0);
        liquidityNorm.push(0);
        x.push(0);
        fees.push(0);
        a.push(0);
        // redemption.push();
        decimals.push(IERC20Metadata(token).decimals());
    }

    // Price between tokenA and tokenB depends on the ratio of [(a-x)/a] /[(b-y)/b]. 
    // This is from the partial derivative of the invariant function.
    function getPrice(address tokenA, address tokenB) public view validToken(tokenA) validToken(tokenB) returns (uint256) {

        uint16 i = pos[tokenA];
        uint16 j = pos[tokenB];

        return mul(
            div(
                1e18 - mul(a[i], div(x[i],liquidity[i])), 
                1e18 - mul(a[j], div(x[j],liquidity[j]))
                ), 
            div(mul(a[j],liquidity[i]), mul(a[i],liquidity[j]))
            );
    }

    function sTerm(int256 w, uint256 i) internal view returns (int256) {
        return int256(sqrt2(1e36 - mul2(uint256(w*1e18), liquidityNorm[i]*1e18)));
    }

    function _newton(int8[] memory signs) internal view returns (int256 w) {
        // now bisect to find w
        w = .99e18;
        int256 nHalf = int256(int24(n))*.5e18;
        int256 lsum_ = int256(lsum);
        int256 newton = 1e18;
        int256[] memory s = new int256[](n);
        int256[] memory s_ = new int256[](n);
        while (abs(newton) > 1e3) {
            require(w <= 1e18, "w out of bounds, w > 1e18");
            int256 fx_ = 0;
            int256 dfx_ = 0;
            for (uint i = 0; i < n; i++) {
                s[i] = sTerm(w, i);
                s_[i] = s[i] * signs[i];
                fx_ += s_[i];
                dfx_ += div(int256(liquidityNorm[i]), s_[i]);
                // console.log("dfx term", div(int256(liquidityNorm[i]), s_[i]));
                // console.log("s_[i]", s_[i]);
                // console.log("signs[i]", signs[i]);
            }
            // console.log("sSum", sSum);
            int256 fx = nHalf - 1e18 - mul(w, lsum_)/4 - fx_/2;
            int256 dfx = -lsum_ + dfx_/4;
            newton = div(fx, dfx);
            console.log("fx", fx);
            console.log("dfx", dfx);
            console.log("newton", newton);

            console.log("w before", w);
            w = w - newton;
            // console.log("w", w);
        }
    }


    function getAllSigns() public view returns (int8[][] memory signs) {
        uint256 combinations = 2 ** n;
        signs = new int8[][](combinations);
        for (uint256 c = 0; c < combinations; c++) {
            signs[c] = new int8[](n);
            for (uint256 i = 0; i < n; i++) {
                if ((c & (1 << i)) != 0) {
                    signs[c][i] = 1;
                } else {
                    signs[c][i] = -1;
                }
            }
        }
    }

    function getSigns() internal view returns (int8[] memory signs) {

        int256[] memory r = new int256[](n);
        signs = new int8[](n);
        for (uint i = 0; i < n; i++) {
            r[i] = int256(sqrt(1e18 - liquidityNorm[i]));
        }
        int256 target = int256(lsum) - int64(1e18*n)/2 + 1e18;
        int256 current = 0;
        for (int24 i = int24(n-1); i >= 0; i--) {
            uint16 o = order[uint24(i)];
            if (abs(target - (current + r[o]) ) < abs(target - (current - r[o]))) {
                current += r[o];
                signs[o] = 1;
            } else {
                current -= r[o];
                signs[o] = -1;
            }
            // console.log("i", i);
            // console.log("o", o);
            // console.log("current", current);
            // console.log("target", target);
            // console.log("r[o]", r[o]);
            // console.log("signs[o]", signs[o]);
        }
    }

    // function fx_(int256 w, int8[] memory signs) internal view returns (int256 sSum) {
    //     int256 s = 0;
    //     for (uint i = 0; i < n; i++) {
    //         s = int256(signs[i]) * sTerm(w, i);
    //         console.log("s", s);
    //         sSum += s;

    //     }
    //     sSum = int256(uint256(n))*1e18 - 1e18 - mul(int256(w), int256(lsum)) + sSum;
    //     console.log("sSum", sSum);


    // }

    function checkForSolution(int8[] memory signs) internal view returns (bool) {
        int256 s = 0;
        int8 prev = 0;
        int256 nHalf = int256(int24(n))*.5e18;
        for (int w = 1e18; w > 0; w -= 1e17) {
            s = 0;
            for (uint i = 0; i < n; i++) {
                s += int256(signs[i]) * sTerm(w, i) ;
                // console.log("signs[i]", signs[i]);
                // console.log("sTerm", sTerm(w, i));
            }
            s = nHalf - 1e18 - mul(int256(lsum), w)/4 - s/2;
            // console.log("w", w);
            // console.log("prev", prev);
            // console.log("s", s);
            if (prev>0 && s < 0) {
                return true;
            } else if (prev<0 && s > 0) {
                return true;
            }
            prev = s > 0 ? int8(1) : int8(-1);
        }
        return false;
    }

    function calculateA() internal{
        int8[][] memory signs = getAllSigns();
        uint8 combinations = uint8(2 ** n);
        for (uint8 c = 0; c < combinations; c++) {
            if(checkForSolution(signs[c])) {
                int256 w = _newton(signs[c]);
                for (uint j = 0; j < n; j++) {
                    // console.log("liquidity[j]", liquidity[j]);
                    // console.log("liquidityNorm[j]", liquidityNorm[j]);
                    a[j] = uint256(1e18 - int256(signs[c][j])*int256(sqrt(1e18 - mul(uint256(w), liquidityNorm[j]))));
                    console.log("a[j]", a[j]);
                }
                return;
            }
        }
    }


    function calculateA_() internal{
        int8[] memory signs = getSigns();
        if(!checkForSolution(signs)) {
            // try to find a better set of signs
            // currently just revert
            revert("No solution found for current liquidity");
        }

        int256 w_ = _newton(signs);
        for (uint i = 0; i < n; i++) {
            a[i] = uint256(1e18 - int256(signs[i])*int256(sqrt(1e18 - mul(uint256(w_), liquidityNorm[i]))));
        }
    }

    function calcLiq( uint256 amount, uint16 decimal) internal pure returns (uint256 liq) {

        if (18 > decimal) {
            liq = amount * (10 ** uint16(18 - decimal));
        } else if (18 < decimal) {
            liq = amount / (10 ** uint16(decimal - 18));
        } else {
            liq = amount;
        }
    }
    function calcTransfer( uint256 liq, uint16 decimal) internal pure returns (uint256 amount) {

        if (18 > decimal) {
            amount = liq / (10 ** uint16(18 - decimal));
        } else if (18 < decimal) {
            amount = liq * (10 ** uint16(decimal - 18));
        } else {
            amount = liq;
        }
    }
    function calcLiq( int256 amount, uint16 decimal) internal pure returns (int256 liq) {

        if (18 > decimal) {
            liq = amount * int256(10 ** (18 - decimal));
        } else if (18 < decimal) {
            liq = amount / int256(10 ** (decimal - 18));
        } else {
            liq = amount;
        }
    }
    function calcTransfer( int256 liq, uint16 decimal) internal pure returns (int256 amount) {

        if (18 > decimal) {
            amount = liq / int256(10 ** (18 - decimal));
        } else if (18 < decimal) {
            amount = liq * int256(10 ** (decimal - 18));
        } else {
            amount = liq;
        }
    }
    function addLiquidity(address token, uint128 amount) public validToken(token) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        modLiquidity(token, int128(amount));
    }
    // This will be a permit2 version later
    function addLiquidity(address token, uint256 amount) public validToken(token) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        modLiquidity(token, int256(amount));
    }
    // This will be a permit2 version later
    function modLiquidity(address token, int256 amount) public validToken(token) {
        uint16 i = pos[token];
        int256 liq = int256(calcLiq(amount, decimals[i]));
        bool remove = amount < 0;
        address from = remove ? address(this) : msg.sender;
        address to = remove ? msg.sender : address(this);
        liquidity[i] = uint256(int256(liquidity[i]) + liq);
        x[i] = uint256(int256(x[i]) + liq);
        bubble(i, remove);
        updateTotal();
        calculateA();
        if (remove) require(liquidity[i] >= abs_(liq), "Insufficient liquidity");
        IERC20(token).safeTransferFrom(from, to, abs_(amount));
    }

    function updateTotal() public {
        lsum = 0;
        for (uint16 i = 0; i < n; i++) {
            liquidityNorm[i] = div(liquidity[i], lmax);
            console.log("liq[i]", liquidity[i]);
            console.log("norm[i]", liquidityNorm[i]);
            console.log("lmax", lmax);
            lsum += liquidityNorm[i];
            minSurpassed[tokens[i]] = liquidity[i] > minLiquidity[i];

        }
    }

    function swap(address tokenOut, address tokenIn, uint256 amountIn) public validToken(tokenOut) validToken(tokenIn) {
        swap(tokenOut, tokenIn, amountIn, msg.sender);
    }


    function swap(address tokenOut, address tokenIn, uint256 swapAmountIn, address to) public validToken(tokenOut) validToken(tokenIn) {
        uint16 i = pos[tokenIn];
        uint16 j = pos[tokenOut];
        uint256 amountIn = calcLiq(swapAmountIn, decimals[i]);
        uint256 amountOut = getSwapAmount(amountIn, a[i], a[j], liquidity[i],liquidity[j],x[i],x[j]);
        uint256 swapAmountOut = calcTransfer(amountOut, decimals[j]);
        require(x[j] >= amountOut, "Insufficient reserves for output token");
        x[i] += amountIn;
        x[j] -= amountOut;
        IERC20(tokenOut).safeTransferFrom(msg.sender, address(this), swapAmountIn);
        IERC20(tokenIn).safeTransfer(to, swapAmountOut);
    }


    function getSwapAmount(uint256 amountIn, uint256 ai, uint256 ao, uint256 liqIn, uint256 liqOut, uint256 xi, uint256 xo) public pure returns (uint256 amountOut) {
        // symmetric for out and in
        uint x2y2 = sq(1e18 - muldiv(xi, ai, liqIn)) + sq(1e18 - muldiv(xo, ao, liqOut));
        uint256 s_ = x2y2 - sq(1e18 - muldiv(xi + amountIn, ai, liqIn));
        amountOut =  muldiv(1e18-sqrt(s_), liqOut, ao);
    }


    function sq(uint256 x_) internal pure returns (uint256) {return mul(x_, x_);}
    function muldiv(uint256 x_, uint256 y_, uint256 z_) internal pure returns (uint256) {return x_ * y_ / z_;}
    function mul(uint256 x_, uint256 y_) internal pure returns (uint256) {return x_ * y_ / 1e18;}
    function mul2(uint256 x_, uint256 y_) internal pure returns (uint256) {return x_ * y_ / 1e36;}
    function mul(int256 x_, int256 y_) internal pure returns (int256) {return x_ * y_ / 1e18;}
    function div(uint256 x_, uint256 y_) internal pure returns (uint256) {return x_ * 1e18 / y_;}
    function div(int256 x_, int256 y_) internal pure returns (int256) {return x_ * 1e18 / y_;}
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
    function abs_(int256 x_) internal pure returns (uint256) {return uint256(x_ >= 0 ? x_ : -x_);}
    function abs(int256 x_) internal pure returns (int256) {return int256(x_ >= 0 ? x_ : -x_);}
    function sub(uint256 x_, int256 y_) internal pure returns (uint256) {
        require(y_ >= 0 ? x_ >= uint256(y_) : true, "Underflow in subtraction");
        return x_ >= uint256(y_) ? x_ - uint256(y_) : 0;}
}