// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ParentReserveVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Contract allowed to move reserves out and deposit fees.
    address public parent;

    event ReserveSent(address indexed to, uint256 amount);
    event FeesDeposited(address indexed from, uint256 amount);

    modifier onlyParent() {
        require(msg.sender == parent, "NotParent");
        _;
    }

    constructor(
        IERC20 asset_,         // underlying reserve asset (e.g., USDC)
        address parent_,       // parent/controller contract
        string memory name_,   // share token name
        string memory symbol_  // share token symbol
    )
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {
        require(parent_ != address(0), "Parent=0");
        parent = parent_;
    }

    function initialize(
        IERC20 asset_,         // underlying reserve asset (e.g., USDC)
        address parent_,       // parent/controller contract
        string memory name_,   // share token name
        string memory symbol_  // share token symbol
    )
        public
    {
        require(parent_ != address(0), "Parent=0");
        parent = parent_;
    }

    /**
     * @notice Parent pulls reserves out to another address.
     * @dev This does NOT mint/burn shares and will reduce vault liquidity.
     *      Use with care; withdraw/redeem are naturally limited by available liquidity.
     */
    function sendReserveTo(address to, uint256 amount)
        external
        onlyParent
        nonReentrant
    {
        IERC20(asset()).safeTransfer(to, amount);
        emit ReserveSent(to, amount);
    }

    /**
     * @notice Parent deposits fees into the vault WITHOUT minting shares.
     * @dev Increases totalAssets and thus share price for existing depositors.
     *      Parent must approve this contract to spend `amount` of the asset first.
     */
    function depositFees(uint256 amount)
        external
        onlyParent
        nonReentrant
    {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit FeesDeposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                      LIQUIDITY-AWARE WITHDRAW LIMITS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Available reserves on-hand in the vault.
     * @dev Doesn’t count assets loaned out / moved to parent.
     */
    function availableReserves() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @dev Limit maxWithdraw to what’s actually liquid.
     *     (OZ’s default can be more permissive; we enforce a hard cap by liquidity.)
     */
    function maxWithdraw(address owner)
        public
        view
        override
        returns (uint256)
    {
        uint256 liquid = availableReserves();
        uint256 claim = convertToAssets(balanceOf(owner));
        return claim < liquid ? claim : liquid;
    }

    /**
     * @dev Limit maxRedeem by liquid reserves translated into shares.
     */
    function maxRedeem(address owner)
        public
        view
        override
        returns (uint256)
    {
        uint256 liquidShares = convertToShares(availableReserves());
        uint256 bal = balanceOf(owner);
        return liquidShares < bal ? liquidShares : bal;
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL: HOOKS & SAFETY NOTES
    //////////////////////////////////////////////////////////////*/
    /**
     * Notes:
     * - totalAssets(): we inherit OZ’s default which uses current on-chain
     *   asset balance by default. Because the parent can move reserves out,
     *   totalAssets will reflect only what’s in the vault. If you want
     *   “receivables” accounting (i.e., track IOU from parent), you could
     *   override totalAssets() to add an off-chain/on-chain tracked amount.
     *
     * - If you later add pausing/circuit breakers, consider OpenZeppelin
     *   Pausable and override deposit/withdraw/redeem/mint accordingly.
     *
     * - Consider an emergency token sweep for non-asset tokens sent by mistake.
     */
}
