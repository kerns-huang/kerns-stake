// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// 质押合约（UUPS 可升级代理实现；部署后需通过代理调用 initialize）
contract MetaNodeStake is Initializable, PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;
    
    // 质押资金池
    struct Pool {
        // 质押代币的地址
        address stTokenAddress;
        // 不同资金池所占的权重，根据池子的重要性设置权重，权重越高，用户质押在这个池子里获得的奖励就越多
        uint256 poolWeight;
        // 上次奖励发放的区块高度
        uint256 lastRewardBlock;
        // 每一份抵押可以分到的token数量
        uint256  accMetaNodePerToken;
        // 质押的代币数量
        uint256 stTokenAmount;
        // 最小质押数量
        uint256  minDepositAmount;
        // 解质押锁定区块数，防止挤兑性提取
        uint256 unstackLockedBlocks;
    }

    struct UnstakeRequest{
        uint256 amount; //用户取消质押的代币数量，要取出多少个token
        uint256 unlockBlock;//解质押的区块高度
    }

    struct User{
        // 质押的代币数量
        uint256 stTokenAmount;
        // 解质押锁定区块数
        uint256 finishedMetaNode;
        // 待发放的meta代币数量
        uint256 pendingMetaNode;
        // 取消质押的请求记录
        UnstakeRequest[] unstakeRequests;
    }

    uint256  public startBlock; // 质押开始区块高度

    uint256 public endBlock; // 质押结束区块高度

    uint256 public metaNodePerBlock; // 每个区块能产出的metanode奖励数量

    bool public withdrawPaused; // 是否暂停提现

    bool public claimPaused; // 是否暂停领取奖励

    IERC20 public metaNode;  // meta代币地址

    uint256 public totalPoolWeight;// 所有池的权重和

    // 质押资金池列表
    Pool[] public pools;

    // 每个池里面用户的质押信息
    mapping(uint256 => mapping(address =>User)) public userInfos;



    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // 由代理在首次部署时调用一次，授予 defaultAdmin 默认管理员角色（含升级权限）
    function initialize(IERC20 _metaNode,uint256 _startBlock,uint256 _endBlock,uint256 _metaNodePerBlock) public initializer {
        __Pausable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        startBlock = startBlock;
        endBlock = _endBlock;
        metaNodePerBlock = _metaNodePerBlock;
        metaNode = _metaNode;   
    }

    event PoolAdded(address indexed stTokenAddress, uint256 poolWeight, uint256 minDepositAmount, uint256 unstackLockedBlocks);

    // 检查pid是否合法
    modifier checkPid(uint256 _pid) {
         require(_pid < pools.length,"invalid pid");
         _;
    }
    //设置每个区块产出的meta代币数量
    function setMetaNodePerBlock(uint256 _metaNodePerBlock) public onlyRole(DEFAULT_ADMIN_ROLE) {
        metaNodePerBlock = _metaNodePerBlock;
    }



    function setPoolWeight(uint256 pid, uint256 poolWeight) public onlyRole(DEFAULT_ADMIN_ROLE) checkPid(pid) {
        // 修改池子权重，更新总权重
        totalPoolWeight = totalPoolWeight - pools[pid].poolWeight + poolWeight;
        pools[pid].poolWeight = poolWeight;
    }


    /**
     * @notice 添加质押资金池
     * @param stTokenAddress 质押代币的地址
     * @param poolWeight 不同资金池所占的权重
     * @param minDepositAmount 最小质押数量
     * @param unstackLockedBlocks 解质押锁定区块数
     */
    function addPool(address stTokenAddress, uint256 poolWeight, uint256 minDepositAmount, uint256 unstackLockedBlocks) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(unstackLockedBlocks > 0 ,"");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        // 更新总权重
        totalPoolWeight += poolWeight;
        //添加资金池
        pools.push(Pool({
            stTokenAddress: stTokenAddress,
            poolWeight: poolWeight,
            lastRewardBlock: lastRewardBlock,
            accMetaNodePerToken: 0,
            stTokenAmount: 0,
            minDepositAmount: minDepositAmount,
            unstackLockedBlocks: unstackLockedBlocks
        }));

        emit PoolAdded(stTokenAddress, poolWeight, minDepositAmount, unstackLockedBlocks);
    }

    /**
     * @notice 添加质押
     * @param pid 资金池ID
     * @param amount 质押金额
     */
    function _deposit(uint256 pid, uint256 amount) public {
        // 质押的金额得大于最小质押金额
        // 当前是否在质押期，如果是在生息期，则不能进行质押
        Pool storage pool = pools[pid];
        // 当前池里面用户的质押信息
        User storage user = userInfos[pid][msg.sender];
        require(amount >= pool.minDepositAmount, "amount < minDepositAmount");
        // 更新池信息，为什么要在质押的时候更新池子信息，因为链上不是太好用定时器，只能在每次质押的时候更新池子信息。
        updatePool(pid);
        //如果用户有质押，计算奖励
        if(user.stTokenAmount > 0){
              bool success = false;
              uint256 reward = 0;
              // 计算用户的质押金额能拿到多少个meta代币
              (success, reward) = user.stTokenAmount.tryMul(pool.accMetaNodePerToken);
              require(success, "mul overflow");
              // 将奖励转换为ether为单位
              (success, reward) = reward.tryDiv(1 ether);
              require(success, "div by zero");
              // 计算用户已经领取的奖励
              (success, reward)=reward.trySub(user.finishedMetaNode);
              require(success, "sub overflow");
              // 将奖励添加到用户的待发放奖励中
              user.pendingMetaNode += reward;
        }
        if(amount > 0){
            // 增加用户的质押金额
            user.stTokenAmount += amount;
            // 增加池子的质押金额
            pool.stTokenAmount += amount;
        }
    }
    // 计算用户等待领取的奖励
    function pendingReward(uint256 _pid, address userAddress) public view returns (uint256 reward){
        Pool storage pool = pools[_pid];
        User storage user = userInfos[_pid][userAddress];
        // 计算用户的质押金额能拿到多少个meta代币
        bool success = false;
        uint256 pendingReward = 0;
        (success, pendingReward) = user.stTokenAmount.tryMul(pool.accMetaNodePerToken);
        require(success, "mul overflow");
        // 将奖励转换为ether为单位
        (success, pendingReward) = pendingReward.tryDiv(1 ether);
        require(success, "div by zero");
        // 计算用户已经领取的奖励
        (success, pendingReward)=pendingReward.trySub(user.finishedMetaNode);
        require(success, "sub overflow");
        // 将奖励添加到用户的待发放奖励中
        reward = user.pendingMetaNode + pendingReward;
    }
    // 计算奖励
    function calPoolReward(uint256 _fromBlock,uint256 _toBlock) public view returns (uint256 reward){
        require(_fromBlock < _toBlock, "fromBlock < toBlock");
        if(_fromBlock < startBlock){
            _fromBlock = startBlock;
        }
        if(_toBlock > endBlock){
            _toBlock = endBlock;
        }
        bool success = false;
        (success, reward) = (_toBlock - _fromBlock).tryMul(metaNodePerBlock);
        require(success, "mul overflow");
        return reward;
    }
    // 更新池子信息
    function updatePool(uint256 _pid) public checkPid(_pid) {
          Pool storage pool = pools[_pid];
          if(block.number <= pool.lastRewardBlock){
             //区块高度没有变化，不需要重复调用。
             return;
          }
          // 这主要是为了做什么？
          if(pool.stTokenAmount > 0){
            // 计算池子在上次产出区块和当前区块之间产出的奖励meta代币数量
            uint256 totalReward = calPoolReward(pool.lastRewardBlock, block.number);
            bool ok;
            uint256 weighted;
            // 计算池子在所有池子中的权重
            (ok, weighted) = totalReward.tryMul(pool.poolWeight);
            require(ok, "mul overflow");
            uint256 poolReward;
            uint256 accMetaNodePerToken;
            (ok, accMetaNodePerToken) = weighted.tryDiv(totalPoolWeight);
            require(ok, "div by zero");
            // 更新池子信息
            pool.lastRewardBlock = block.number;
            //计算每个token得到的
            pool.accMetaNodePerToken = accMetaNodePerToken;
          }
          
    }
    /**
     * @notice 取消质押，把质押中的代币从质押中取出，进入解质押的锁定期，等到锁定期结束后，用户才能提取这些代币。
     * @param pid 资金池ID
     * @param amount 取消质押金额
     */
    function unstake(uint256 _pid, uint256 _amount) public checkPid(_pid) {
        // 取消质押，用户发起取消质押请求，记录取消质押的数量和解质押的区块高度，等到解质押的区块高度到达后，用户才能提取取消质押的代币。
         Pool storage pool = pools[_pid];
         User storage user = userInfos[_pid][msg.sender];
         // 用户必须有质押的代币才能取消质押
        require(user.stTokenAmount >= _amount, "unstake amount exceeds staked amount");
         // 更新池子信息，计算奖励  
        updatePool(_pid);
            // 计算用户的质押金额能拿到多少个meta代币
            //总的应得token数量=用户质押的数量*每个token能得到的meta代币数量-用户已经领取的meta代币数量
        uint256 pendingMetaNode=user.stTokenAmount *pool.accMetaNodePerToken / 1 ether - user.finishedMetaNode;
        if(pendingMetaNode > 0){
            // 将奖励添加到用户的待发放奖励中
            user.pendingMetaNode += pendingMetaNode;
            // 更新用户已经领取的meta代币数量
            user.finishedMetaNode += pendingMetaNode;
        }
        if(_amount > 0){
            // 增加用户的取消质押请求记录
            user.unstakeRequests.push(UnstakeRequest({
                amount: _amount,
                unlockBlock: block.number + pool.unstackLockedBlocks
            }));
            // 减少用户的质押数量
            user.stTokenAmount -= _amount;
            // 减少池子的质押数量
            pool.stTokenAmount -= _amount;
        }

    }
    /**
     * @notice 领取奖励，用户可以领取自己质押获得的meta代币奖励。
     * @param pid 资金池ID 
     */
    function claimReward(uint256 _pid) public checkPid(_pid){
        Pool storage pool = pools[_pid];
        User storage user = userInfos[_pid][msg.sender];
        require(!claimPaused, "claim is paused");
        // 更新池子信息，计算奖励
        updatePool(_pid);
        // 计算用户的质押金额能拿到多少个meta代币,这个逻辑有点问题
        uint256 pendingMetaNode_ = (user.stTokenAmount * pool.accMetaNodePerToken) /
            (1 ether) -
            user.finishedMetaNode +
            user.pendingMetaNode;
         if (pendingMetaNode_ > 0) {
            user.pendingMetaNode = 0;
            _safeMetaNodeTransfer(msg.sender, pendingMetaNode_);
            // 更新用户已经领取的meta代币数量
          }
    }
    
    // 提取质押的代币
    function withdraw(uint256 _pid) checkPid(_pid) public{
        Pool storage pool = pools[_pid];
        User storage user = userInfos[_pid][msg.sender];
        uint256 withdrawableAmount = 0;
        // 遍历用户的取消质押请求记录，找出所有解质押区块高度已经到达的请求，计算可提取的代币数量，并从用户的取消质押请求记录中删除这些请求
        //倒排操作，避免删除元素后数组前移导致的漏处理问题
        for (uint256 i = user.unstakeRequests.length; i > 0; i--) {
            uint256 idx = i - 1;
            if (block.number >= user.unstakeRequests[idx].unlockBlock) {
                withdrawableAmount += user.unstakeRequests[idx].amount;
                user.unstakeRequests[idx] = user.unstakeRequests[user.unstakeRequests.length - 1];
                user.unstakeRequests.pop();
           }
        }
        // 提现代币
        if(withdrawableAmount > 0){
            if(pool.stTokenAddress == address(0)){
                // 如果质押的代币是以太币，直接转账给用户
                Address.sendValue(payable(msg.sender), withdrawableAmount);
            }else{
                // 如果质押的代币是ERC20代币，转账给用户
                IERC20(pool.stTokenAddress).safeTransfer(msg.sender, withdrawableAmount);   
        }
    }
    

    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
        uint256 bal = metaNode.balanceOf(address(this));
        metaNode.safeTransfer(_to, _amount > bal ? bal : _amount);
    }





    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {

    }
}
