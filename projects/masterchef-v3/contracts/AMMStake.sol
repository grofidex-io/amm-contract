// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/SafeCast.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/INonfungiblePositionManagerStruct.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./interfaces/IWETH.sol";
import "./utils/Multicall.sol";
import "./Enumerable.sol";

contract AMMStake is INonfungiblePositionManagerStruct, Multicall, Ownable, ReentrancyGuard, Enumerable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    struct PoolInfo {
        // V3 pool address
        IPancakeV3Pool v3Pool;
        // V3 pool token0 address
        address token0;
        // V3 pool token1 address
        address token1;
        // V3 pool fee
        uint24 fee;
        uint256 tokensPerSecond;
    }

    struct UserPositionInfo {
        address user;
        uint256 pid;
        uint128 liquidity;
        uint64 latestClaimReward;
    }

    uint256 public poolLength;
    /// @notice Info of each MCV3 pool.
    mapping(uint256 => PoolInfo) public poolInfo;

    /// @notice userPositionInfos[tokenId] => UserPositionInfo
    /// @dev TokenId is unique, and we can query the pid by tokenId.
    mapping(uint256 => UserPositionInfo) public userPositionInfos;

    /// @notice v3PoolPid[token0][token1][fee] => pid
    mapping(address => mapping(address => mapping(uint24 => uint256))) v3PoolPid;
    /// @notice v3PoolAddressPid[v3PoolAddress] => pid
    mapping(address => uint256) public v3PoolAddressPid;

    /// @notice Address of CAKE contract.
    IERC20 public immutable CAKE;

    /// @notice Address of WETH contract.
    address public immutable WETH;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice Address of the operator.
    address public operatorAddress;

    error ZeroAddress();
    error NotOwnerOrOperator();
    error NotPancakeNFT();
    error InvalidNFT();
    error NotOwner();
    error NoLiquidity();
    error InvalidPid();
    error DuplicatedPool(uint256 pid);
    error NotEmpty();
    error WrongReceiver();
    error InconsistentAmount();
    error InsufficientAmount();

    event AddPool(uint256 indexed pid, IPancakeV3Pool indexed v3Pool);
    event SetPool(uint256 indexed pid, uint256 allocPoint);
    event Deposit(
        address indexed from,
        uint256 indexed pid,
        uint256 indexed tokenId
    );
    event Withdraw(address indexed from, address to, uint256 indexed pid, uint256 indexed tokenId);
    event UpdateLiquidity(
        address indexed from,
        uint256 indexed pid,
        uint256 indexed tokenId,
        int128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event NewOperatorAddress(address operator);
    event NewReceiver(address receiver);
    event NewPeriodDuration(uint256 periodDuration);
    event Harvest(address indexed sender, address to, uint256 indexed pid, uint256 indexed tokenId, uint256 reward);
    event UpdateFarmBoostContract(address indexed farmBoostContract);
    event SetEmergency(bool emergency);

    modifier onlyOwnerOrOperator() {
        if (msg.sender != operatorAddress && msg.sender != owner()) revert NotOwnerOrOperator();
        _;
    }

    modifier onlyValidPid(uint256 _pid) {
        if (_pid == 0 || _pid > poolLength) revert InvalidPid();
        _;
    }

    constructor(IWETH _CAKE, INonfungiblePositionManager _nonfungiblePositionManager, address _WETH) {
        CAKE = _CAKE;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        WETH = _WETH;
    }

    /// @notice View function for checking pending CAKE rewards.
    /// @param _tokenId Token Id of NFT.
    /// @return reward Pending reward.
    function pendingCake(uint256 _tokenId) external view returns (uint256 reward) {
        UserPositionInfo memory positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.pid != 0) {
            PoolInfo memory pool = poolInfo[positionInfo.pid];
            reward = pool.tokensPerSecond * (block.timestamp - uint256(positionInfo.latestClaimReward));
        }
    }

    function add(IPancakeV3Pool _v3Pool, uint256 _tokensPerSecond) external onlyOwner {

        address token0 = _v3Pool.token0();
        address token1 = _v3Pool.token1();
        uint24 fee = _v3Pool.fee();
        if (v3PoolPid[token0][token1][fee] != 0) revert DuplicatedPool(v3PoolPid[token0][token1][fee]);
        if (IERC20(token0).allowance(address(this), address(nonfungiblePositionManager)) == 0)
            IERC20(token0).safeApprove(address(nonfungiblePositionManager), type(uint256).max);
        if (IERC20(token1).allowance(address(this), address(nonfungiblePositionManager)) == 0)
            IERC20(token1).safeApprove(address(nonfungiblePositionManager), type(uint256).max);
        unchecked {
            poolLength++;
        }
        poolInfo[poolLength] = PoolInfo({
            v3Pool: _v3Pool,
            token0: token0,
            token1: token1,
            fee: fee,
            tokensPerSecond: _tokensPerSecond
        });

        v3PoolPid[token0][token1][fee] = poolLength;
        v3PoolAddressPid[address(_v3Pool)] = poolLength;
        emit AddPool(poolLength, _v3Pool);
    }

    // function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner onlyValidPid(_pid) {
    //     uint32 currentTime = uint32(block.timestamp);
    //     PoolInfo storage pool = poolInfo[_pid];
    //     ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
    //     if (address(LMPool) != address(0)) {
    //         LMPool.accumulateReward(currentTime);
    //     }

    //     if (_withUpdate) massUpdatePools();
    //     totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
    //     pool.allocPoint = _allocPoint;
    //     emit SetPool(_pid, _allocPoint);
    // }

    struct DepositCache {
        address token0;
        address token1;
        uint24 fee;
        uint128 liquidity;
    }

    /// @notice Upon receiving a ERC721
    function onERC721Received(
        address,
        address _from,
        uint256 _tokenId,
        bytes calldata
    ) external nonReentrant returns (bytes4) {
        if (msg.sender != address(nonfungiblePositionManager)) revert NotPancakeNFT();
        DepositCache memory cache;
        (
            ,
            ,
            cache.token0,
            cache.token1,
            cache.fee,
            ,
            ,
            cache.liquidity,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(_tokenId);
        if (cache.liquidity == 0) revert NoLiquidity();
        uint256 pid = v3PoolPid[cache.token0][cache.token1][cache.fee];
        if (pid == 0) revert InvalidNFT();

        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];

        positionInfo.user = _from;
        positionInfo.pid = pid;
        positionInfo.latestClaimReward = uint64(block.timestamp);

        updateLiquidityOperation(positionInfo, _tokenId);
        emit Deposit(_from, pid, _tokenId);

        return this.onERC721Received.selector;
    }

    function harvest(uint256 _tokenId, address _to) external nonReentrant returns (uint256 reward) {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (positionInfo.liquidity == 0) revert NoLiquidity();
        reward = harvestOperation(positionInfo, _tokenId, _to);
    }

    function harvestOperation(
        UserPositionInfo storage positionInfo,
        uint256 _tokenId,
        address _to
    ) internal returns (uint256 reward) {
        PoolInfo memory pool = poolInfo[positionInfo.pid];
        reward = pool.tokensPerSecond * (block.timestamp - uint256(positionInfo.latestClaimReward));
        positionInfo.latestClaimReward = uint64(block.timestamp);
        if (reward > 0) {
            if (_to != address(0)) {
                _safeTransfer(_to, reward);
                emit Harvest(msg.sender, _to, positionInfo.pid, _tokenId, reward);
            }
        }
    }

    function withdraw(uint256 _tokenId, address _to) external nonReentrant returns (uint256 reward) {
        if (_to == address(this) || _to == address(0)) revert WrongReceiver();
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        reward = harvestOperation(positionInfo, _tokenId, _to);
        uint256 pid = positionInfo.pid;
        delete userPositionInfos[_tokenId];
        removeToken(msg.sender, _tokenId);
        nonfungiblePositionManager.safeTransferFrom(address(this), _to, _tokenId);
        emit Withdraw(msg.sender, _to, pid, _tokenId);
    }

    function updateLiquidity(uint256 _tokenId) external nonReentrant {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.pid == 0) revert InvalidNFT();
        harvestOperation(positionInfo, _tokenId, address(0));
        updateLiquidityOperation(positionInfo, _tokenId);
    }

    function increaseLiquidity(
        IncreaseLiquidityParams memory params
    ) external payable nonReentrant returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        UserPositionInfo storage positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.pid == 0) revert InvalidNFT();
        PoolInfo memory pool = poolInfo[positionInfo.pid];
        pay(pool.token0, params.amount0Desired);
        pay(pool.token1, params.amount1Desired);
        if (pool.token0 != WETH && pool.token1 != WETH && msg.value > 0) revert();
        (liquidity, amount0, amount1) = nonfungiblePositionManager.increaseLiquidity{value: msg.value}(params);
        uint256 token0Left = params.amount0Desired - amount0;
        uint256 token1Left = params.amount1Desired - amount1;
        if (token0Left > 0) {
            refund(pool.token0, token0Left);
        }
        if (token1Left > 0) {
            refund(pool.token1, token1Left);
        }
        harvestOperation(positionInfo, params.tokenId, address(0));
        updateLiquidityOperation(positionInfo, params.tokenId);
    }

    function pay(address _token, uint256 _amount) internal {
        if (_token == WETH && msg.value > 0) {
            if (msg.value != _amount) revert InconsistentAmount();
        } else {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
    }

    function refund(address _token, uint256 _amount) internal {
        if (_token == WETH && msg.value > 0) {
            nonfungiblePositionManager.refundETH();
            safeTransferETH(msg.sender, address(this).balance);
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    function updateLiquidityOperation(
        UserPositionInfo storage positionInfo,
        uint256 _tokenId
    ) internal {
        (, , , , , , , uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(
            _tokenId
        );
        if (positionInfo.liquidity != liquidity) {
            positionInfo.liquidity = liquidity;
        }
    }

    function decreaseLiquidity(
        DecreaseLiquidityParams memory params
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        UserPositionInfo storage positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(params);
        harvestOperation(positionInfo, params.tokenId, address(0));
        updateLiquidityOperation(positionInfo, params.tokenId);
    }

    function collect(CollectParams memory params) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        UserPositionInfo memory positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (params.recipient == address(0)) params.recipient = address(this);
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
    }

    function collectTo(
        CollectParams memory params,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        UserPositionInfo memory positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (params.recipient == address(0)) params.recipient = address(this);
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
        // Need to refund token to user when recipient is zero address
        if (params.recipient == address(this)) {
            PoolInfo memory pool = poolInfo[positionInfo.pid];
            if (to == address(0)) to = msg.sender;
            transferToken(pool.token0, to);
            transferToken(pool.token1, to);
        }
    }

    function transferToken(address _token, address _to) internal {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance > 0) {
            if (_token == WETH) {
                IWETH(WETH).withdraw(balance);
                safeTransferETH(_to, balance);
            } else {
                IERC20(_token).safeTransfer(_to, balance);
            }
        }
    }

    function unwrapWETH9(uint256 amountMinimum, address recipient) external nonReentrant {
        uint256 balanceWETH = IWETH(WETH).balanceOf(address(this));
        if (balanceWETH < amountMinimum) revert InsufficientAmount();

        if (balanceWETH > 0) {
            IWETH(WETH).withdraw(balanceWETH);
            safeTransferETH(recipient, balanceWETH);
        }
    }

    function burn(uint256 _tokenId) external nonReentrant {
        UserPositionInfo memory positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (positionInfo.liquidity > 0) revert NotEmpty();
        delete userPositionInfos[_tokenId];
        // Update Enumerable
        removeToken(msg.sender, _tokenId);
        // Remove boosted token id in farm booster.
        nonfungiblePositionManager.burn(_tokenId);
        emit Withdraw(msg.sender, address(0), positionInfo.pid, _tokenId);
    }
    /// @notice Set operator address.
    /// @dev Callable by owner
    /// @param _operatorAddress New operator address.
    function setOperator(address _operatorAddress) external onlyOwner {
        if (_operatorAddress == address(0)) revert ZeroAddress();
        operatorAddress = _operatorAddress;
        emit NewOperatorAddress(_operatorAddress);
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}("");
        if (!success) revert();
    }

    function _safeTransfer(address _to, uint256 _amount) internal {
      if (_amount > 0) {
          uint256 balance = CAKE.balanceOf(address(this));
          if (balance < _amount) {
              _amount = balance;
          }
          CAKE.safeTransfer(_to, _amount);
      }
    }

    receive() external payable {
        if (msg.sender != address(nonfungiblePositionManager) && msg.sender != WETH) revert();
    }
}
