// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {
    AccessControlUpgradeable,
    Address,
    ERC20PermitUpgradeable,
    ERC20Upgradeable,
    IERC20,
    IERC20Metadata,
    Math,
    ReentrancyGuardUpgradeable,
    SafeERC20
} from "./Common.sol";

import {IVault} from "src/interface/IVault.sol";
import {IRateProvider} from "src/interface/IRateProvider.sol";

contract Vault is IVault, ERC20PermitUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        AssetStorage storage assetStorage = _getAssetStorage();
        return assetStorage.assets[assetStorage.list[0]].decimals;
    }

    function asset() public view returns (address) {
        return _getAssetStorage().list[0];
    }

    function totalAssets() public view returns (uint256) {
        return _getVaultStorage().totalAssets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(asset(), assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(asset(), shares, Math.Rounding.Floor);
    }

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    // QUESTION: How to handle this in v1 with async withdraws.
    function maxWithdraw(address owner) public view returns (uint256) {
        return _convertToAssets(asset(), balanceOf(owner), Math.Rounding.Floor);
    }

    // QUESTION: How to handle this in v1 with async withdraws.
    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(asset(), assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(asset(), shares, Math.Rounding.Ceil);
    }

    // QUESTION: How to handle this? Start disabled, come back later
    // This would have to be it's own Liquidity and Risk Module
    // that calculates the asset ratios and figure out the debt ratio
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToShares(asset(), assets, Math.Rounding.Ceil);
    }

    // QUESTION: How do we handle this?
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _convertToAssets(asset(), shares, Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver) public returns (uint256) {
        if (paused()) revert Paused();

        uint256 shares = previewDeposit(assets);
        _deposit(asset(), _msgSender(), receiver, assets, shares);

        return shares;
    }

    function mint(uint256 shares, address receiver) public virtual returns (uint256) {
        if (paused()) revert Paused();

        uint256 assets_ = previewMint(shares);
        _deposit(asset(), _msgSender(), receiver, assets_, shares);

        return assets_;
    }

    // QUESTION: How to handle this in v1 if no sync withdraws
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        if (paused()) revert Paused();

        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);

        _getVaultStorage().totalAssets -= assets;
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    // QUESTION: How to handle this in v1 with async withdraws
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        if (paused()) revert Paused();

        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);

        _getVaultStorage().totalAssets -= assets;
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    //// 4626-MAX ////

    function getAssets() public view returns (address[] memory) {
        return _getAssetStorage().list;
    }

    function getAsset(address asset_) public view returns (AssetParams memory) {
        return _getAssetStorage().assets[asset_];
    }

    function getStrategies() public view returns (address[] memory) {
        return _getStrategyStorage().list;
    }

    function getStrategy(address asset_) public view returns (StrategyParams memory) {
        return _getStrategyStorage().strategies[asset_];
    }

    function previewDepositAsset(address asset_, uint256 assets_) public view returns (uint256) {
        return _convertToShares(asset_, assets_, Math.Rounding.Floor);
    }

    function depositAsset(address asset_, uint256 assets_, address receiver) public returns (uint256) {
        if (paused()) revert Paused();
        if (_getAssetStorage().assets[asset_].index == 0) revert InvalidAsset();

        uint256 shares = previewDepositAsset(asset_, assets_);
        _deposit(asset_, _msgSender(), receiver, assets_, shares);

        return shares;
    }

    function paused() public view returns (bool) {
        return _getVaultStorage().paused;
    }

    function rateProvider() public view returns (address) {
        return _getVaultStorage().rateProvider;
    }

    function processAssets(address[] calldata strategies, uint256[] memory values, bytes[] calldata data)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!_getStrategyStorage().strategies[strategies[i]].active) revert BadStrategy(strategies[i]);

            (bool success, bytes memory returnData) = strategies[i].call{value: values[i]}(data[i]);

            if (!success) {
                revert ProcessFailed(returnData);
            }
        }
    }

    function processAccounting() public {
        AssetStorage storage assetStorage = _getAssetStorage();
        StrategyStorage storage strategyStorage = _getStrategyStorage();

        for (uint256 i = 0; i < assetStorage.list.length; i++) {
            address asset_ = assetStorage.list[i];
            uint256 assetBalance = IERC20(asset_).balanceOf(address(this));
            uint256 baseAssetBalance = _convertAssetToBase(asset_, assetBalance);
            assetStorage.assets[asset_].idleAssets = baseAssetBalance;
        }

        for (uint256 i = 0; i < strategyStorage.list.length; i++) {
            address strategy = strategyStorage.list[i];
            uint256 strategyBalance = IERC20(strategy).balanceOf(address(this));
            uint256 baseStrategyBalance = _convertAssetToBase(strategy, strategyBalance);
            strategyStorage.strategies[strategy].deployedAssets = baseStrategyBalance;
        }
    }

    //// INTERNAL ////

    function _convertToAssets(address asset_, uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        uint256 baseDenominatedShares = _convertAssetToBase(asset_, shares);
        return baseDenominatedShares.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToShares(address asset_, uint256 assets_, Math.Rounding rounding)
        internal
        view
        returns (uint256)
    {
        uint256 convertedAssets = _convertAssetToBase(asset_, assets_);
        return convertedAssets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertAssetToBase(address asset_, uint256 amount) internal view returns (uint256) {
        uint256 rate = IRateProvider(_getVaultStorage().rateProvider).getRate(asset_);
        return amount.mulDiv(rate, 10 ** _getAssetStorage().assets[asset_].decimals, Math.Rounding.Floor);
    }

    function _convertBaseToAsset(address asset_, uint256 baseAmount) internal view returns (uint256) {
        uint256 rate = IRateProvider(_getVaultStorage().rateProvider).getRate(asset_);
        return baseAmount.mulDiv(10 ** _getAssetStorage().assets[asset_].decimals, rate, Math.Rounding.Floor);
    }

    /// @dev Being Multi asset, we need to add the asset param here to deposit the user's asset accordingly.
    function _deposit(address asset_, address caller, address receiver, uint256 assets, uint256 shares) internal {
        _getVaultStorage().totalAssets += assets;

        SafeERC20.safeTransferFrom(IERC20(asset_), caller, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    // QUESTION: How might we
    function _withdraw(address caller, address receiver, address owner, uint256 assets_, uint256 shares) internal {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(_getAssetStorage().list[0]), receiver, assets_);

        emit Withdraw(caller, receiver, owner, assets_, shares);
    }

    function _decimalsOffset() internal pure returns (uint8) {
        return 0;
    }

    function _getVaultStorage() internal pure returns (VaultStorage storage $) {
        assembly {
            $.slot := 0x22cdba5640455d74cb7564fb236bbbbaf66b93a0cc1bd221f1ee2a6b2d0a2427
        }
    }

    function _getAssetStorage() internal pure returns (AssetStorage storage $) {
        assembly {
            $.slot := 0x2dd192a2474c87efcf5ffda906a4b4f8a678b0e41f9245666251cfed8041e680
        }
    }

    function _getStrategyStorage() internal pure returns (StrategyStorage storage $) {
        assembly {
            $.slot := 0x36e313fea70c5f83d23dd12fc41865566e392cbac4c21baf7972d39f7af1774d
        }
    }

    //// ADMIN ////

    function setRateProvider(address rateProvider_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (rateProvider_ == address(0)) revert ZeroAddress();
        _getVaultStorage().rateProvider = rateProvider_;
        emit SetRateProvider(rateProvider_);
    }

    function addAsset(address asset_, uint8 decimals_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset_ == address(0)) revert ZeroAddress();

        AssetStorage storage assetStorage = _getAssetStorage();
        uint256 index = assetStorage.list.length;
        if (index > 0 && assetStorage.assets[asset_].index != 0) revert InvalidAsset();

        assetStorage.assets[asset_] =
            AssetParams({active: true, index: index, decimals: decimals_, idleAssets: 0, deployedAssets: 0});

        assetStorage.list.push(asset_);

        emit NewAsset(asset_, decimals_, index);
    }

    function toggleAsset(address asset_, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AssetStorage storage assetStorage = _getAssetStorage();
        if (assetStorage.list[0] == address(0)) revert AssetNotFound();
        assetStorage.assets[asset_].active = active;
        emit ToggleAsset(asset_, active);
    }

    function addStrategy(address strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (strategy == address(0)) revert ZeroAddress();

        StrategyStorage storage strategyStorage = _getStrategyStorage();
        uint256 index = strategyStorage.list.length;

        if (index > 0 && strategyStorage.strategies[strategy].index != 0) {
            revert DuplicateStrategy();
        }

        strategyStorage.strategies[strategy] = StrategyParams({active: true, index: index, deployedAssets: 0});

        strategyStorage.list.push(strategy);

        emit NewStrategy(strategy, index);
    }

    function pause(bool paused_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage vaultStorage = _getVaultStorage();
        vaultStorage.paused = paused_;
        emit Pause(paused_);
    }

    // QUESTION: Start with Strategies or add them later
    // vault starts paused because the rate provider and assets / strategies haven't been set
    function initialize(address admin, string memory name, string memory symbol) external initializer {
        // Initialize the vault
        __ERC20_init(name, symbol);
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        _getVaultStorage().paused = true;
    }

    constructor() {
        _disableInitializers();
    }
}