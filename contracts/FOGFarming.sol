// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;


import "./IERC20.sol";
import "./SafeERC20.sol";
import "./SafeMath.sol";
import "./Ownable.sol";
import "./FOGToken.sol";



// FOGFarming is the master of FOG. He can make FOG and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power.
//
// Have fun reading it. Hopefully it's bug-free.

contract NoMist is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.

        uint256 mistRewardDebt; // extra reward debt
        //
        // We do some fancy math here. Basically, any point in time, the amount of FOGs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFOGPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFOGPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. FOGs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that FOGs distribution occurs.
        uint256 accFOGPerShare;   // Accumulated FOGs per share, times 1e12. See below.

        // extra pool reward
        uint256 mistPid;         // PID for extra pool
        uint256 accMistPerShare; // Accumulated extra token per share, times 1e12.
        bool dualFarmingEnable;

        bool emergencyMode;
    }

    // The FOG TOKEN!
    FOGToken public fog;
    // Dev address.
    address public devaddr;
    // The block number when FOG mining starts.
    uint256 public startBlock;
    // Block number when test FOG period ends.
    uint256 public allEndBlock;
    // FOG tokens created per block.
    uint256 public fogPerBlock;
    // Max multiplier
    uint256 public maxMultiplier;
    // sc address for dual farming
    address public mistFarming;          
    // the reward token for dual farming
    address public mist;       

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    uint256 public constant TEAM_PERCENT = 10; 

    uint256 public constant PID_NOT_SET = 0xffffffff; 


    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        FOGToken _fog,
        address _devaddr,
        uint256 _fogPerBlock,
        uint256 _startBlock,
        uint256 _allEndBlock,
        address _mistFarmingAddr,
        address _mistAddr
    ) {
        fog = _fog;
        devaddr = _devaddr;
        startBlock = _startBlock;
        allEndBlock = _allEndBlock;
        fogPerBlock = _fogPerBlock;
        maxMultiplier = 3e12;
        mistFarming = _mistFarmingAddr;
        mist = _mistAddr;
    }

    function setMistPid(uint _pid, uint _mistPid, bool _dualFarmingEnable) public onlyOwner {
        // only support set once
        if (poolInfo[_pid].mistPid == PID_NOT_SET) {
            poolInfo[_pid].mistPid = _mistPid;
        }
        
        poolInfo[_pid].dualFarmingEnable = _dualFarmingEnable;
    }

    function setMaxMultiplier(uint _maxMultiplier) public onlyOwner {
        maxMultiplier = _maxMultiplier;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate, uint _mistPid, bool _dualFarmingEnable) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        uint mistPidUsed = PID_NOT_SET;
        if (_dualFarmingEnable) {
            mistPidUsed = _mistPid;
        }

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accFOGPerShare: 0,
            mistPid: mistPidUsed,
            accMistPerShare: 0,
            dualFarmingEnable: _dualFarmingEnable,
            emergencyMode: false
        }));
    }

    // Update the given pool's FOG allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_from >= allEndBlock) {
            return 0;
        }

        if (_to < startBlock) {
            return 0;
        }

        if (_to > allEndBlock && _from < startBlock) {
            return allEndBlock.sub(startBlock);
        }

        if (_to > allEndBlock) {
            return allEndBlock.sub(_from);
        }

        if (_from < startBlock) {
            return _to.sub(startBlock);
        }

        return _to.sub(_from);
    }

    // View function to see pending FOGs on frontend.
    function pendingFOG(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFOGPerShare = pool.accFOGPerShare;
        
        uint256 lpSupply;
        if (mistFarming == address(0) || !pool.dualFarmingEnable) {
            lpSupply = pool.lpToken.balanceOf(address(this));
        } 

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 fogReward = multiplier.mul(fogPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accFOGPerShare = accFOGPerShare.add(fogReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accFOGPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        
        uint256 lpSupply;
        if (mistFarming == address(0) || !pool.dualFarmingEnable) {
            lpSupply = pool.lpToken.balanceOf(address(this));
            if (lpSupply == 0) {
                if (pool.lastRewardBlock < block.number) {
                    pool.lastRewardBlock = block.number;
                }
                return;
            }
        }
        
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 fogReward = multiplier.mul(fogPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accFOGPerShare = pool.accFOGPerShare.add(fogReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to FOGFarming for FOG allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (user.amount.add(_amount) > 0) {
            uint256 pending = user.amount.mul(pool.accFOGPerShare).div(1e12).sub(user.rewardDebt);
            mintFOG(pending);
            safeFOGTransfer(msg.sender, pending);
        }

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accFOGPerShare).div(1e12);
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from FOGFarming.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accFOGPerShare).div(1e12).sub(user.rewardDebt);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accFOGPerShare).div(1e12);

        mintFOG(pending);
        safeFOGTransfer(msg.sender, pending);

        if (_amount > 0) {

            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }

        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdrawEnable(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        pool.emergencyMode = true;
        pool.dualFarmingEnable = false;
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.emergencyMode, "not enable emergence mode");

        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe FOG transfer function, just in case if rounding error causes pool to not have enough FOGs.
    function safeFOGTransfer(address _to, uint256 _amount) internal {
        uint256 fogBal = fog.balanceOf(address(this));
        if (_amount > fogBal) {
            fog.transfer(_to, fogBal);
        } else {
            fog.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "Should be dev address");
        devaddr = _devaddr;
    }

    function mintFOG(uint amount) private {
        fog.mint(devaddr, amount.mul(TEAM_PERCENT).div(100));
        fog.mint(address(this), amount);
    }
}