// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/pancake/IMasterChef.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";
import "../../utils/GasThrottler.sol";
import "../../interfaces/bunny/IBunnyVault.sol";

/*
    Special Features:
    - Exclusive deposit from balancer [ ] 
    - Optional delegateCompounding() [ ] 
    - Can't deposit() in less than 3 days [ ] 
    - make sure we take EVERY instance of value into account for balanceOf() [ ]
    - Can their DUST const lock our funds? [ ]
    - Add function with large delay that can execute any code? [ ]
*/ 

contract StrategyBunnyCake is StratManager, FeeManager, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public cake = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    address constant public bifi = address(0xCa3F508B8e4Dd382eE878A314789373D80A5190A);
    address constant public bunny = address(0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51);

    // Third party contracts
    address constant public unirouter  = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address constant public bunnyVault = address(0xEDfcB78e73f7bA6aD2D829bf5D462a0924da28eD);

    // Beefy contracts
    address constant public rewardPool  = address(0x453D4Ba9a2D594314DF88564248497F7D74d6b2C);
    address constant public treasury = address(0x4A32De8c248533C28904b24B4cFCFE18E9F2ad01);
    address public vault;

    // Routes
    address[] public bunnyToCakeRoute = [bunny, wbnb, cake];
    address[] public cakeToWbnbRoute = [cake, wbnb];
    address[] public wbnbToBifiRoute = [wbnb, bifi];

    /*
     @param _vault Address of parent vault
     @param _keeper Address of extra maintainer
     @param _strategist Address where stategist fees go.
    */
    constructor(
        address _vault, 
        address _keeper, 
        address _strategist
    ) StratManager(_keeper, _strategist) public {
        vault = _vault;

        _giveAllowances();
    }

    function deposit() public whenNotPaused {
        uint256 cakeBal = balanceOfCake();

        if (cakeBal > 0) {
            IBunnyVault(bunnyVault).deposit(cakeBal);
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 cakeBal = balanceOfCake();

        if (cakeBal < _amount) {
            IBunnyVault(bunnyVault).withdrawUnderlying(_amount.sub(cakeBal));
            cakeBal = balanceOfCake();
        }

        if (cakeBal > _amount) {
            cakeBal = _amount;    
        }
        
        if (tx.origin == owner() || paused()) {
            IERC20(cake).safeTransfer(vault, cakeBal); 
        } else {
            uint256 withdrawalFee = cakeBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(cake).safeTransfer(vault, cakeBal.sub(withdrawalFee)); 
        }
    }

    function harvest() external whenNotPaused onlyEOA gasThrottle {
        IBunnyVault(bunnyVault).getRewards();
        _chargeFees();
        deposit();
    }

    // Performance fees
    function _chargeFees() internal {
        uint256 toCake = IERC20(bunny).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toCake, 0, bunnyToCakeRoute, address(this), now.add(600));

        uint256 toWbnb = IERC20(cake).balanceOf(address(this)).mul(6).div(100);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toWbnb, 0, cakeToWbnbRoute, address(this), now.add(600));
    
        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));
        
        uint256 callFeeAmount = wbnbBal.mul(callFee).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFeeAmount);
        
        uint256 treasuryHalf = wbnbBal.mul(TREASURY_FEE).div(MAX_FEE).div(2);
        IERC20(wbnb).safeTransfer(treasury, treasuryHalf);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(treasuryHalf, 0, wbnbToBifiRoute, treasury, now.add(600));
        
        uint256 rewardsFeeAmount = wbnbBal.mul(rewardsFee).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(rewardPool, rewardsFeeAmount);

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }


    // Calculate the total underlaying {cake} held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfCake().add(balanceOfPool());
    }


    // It calculates how much {cake} the contract holds.
    function balanceOfCake() public view returns (uint256) {
        return IERC20(cake).balanceOf(address(this));
    }

    // It calculates how much {cake} the strategy has allocated in the {bunnyVault}
    function balanceOfPool() public view returns (uint256) {
        return IBunnyVault(bunnyVault).balanceOf(address(this));
    }

    // Called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IBunnyVault(bunnyVault).withdrawUnderlying(uint(-1));

        uint256 cakeBal = balanceOfCake();
        IERC20(cake).transfer(vault, cakeBal);
    }

    // Pauses deposits and withdraws all funds from third party systems.
    function panic() external onlyManager {
        IBunnyVault(bunnyVault).withdrawUnderlying(uint(-1));
        pause();
    }

    function pause() public onlyManager {
        _pause();
        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();
        _giveAllowances();
        deposit();
    }

    function _giveAllowances() internal {
        IERC20(bunny).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
        IERC20(cake).safeApprove(unirouter, uint(-1));
        IERC20(cake).safeApprove(bunnyVault, uint(-1));
    }

    function _removeAllowances() internal {
        IERC20(bunny).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(cake).safeApprove(unirouter, 0);
        IERC20(cake).safeApprove(bunnyVault, 0);
    }

    function inCaseTokensGetStuck(address _token) external onlyManager {
        require(_token != cake, "!safe");
        require(_token != bunny, "!safe");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}