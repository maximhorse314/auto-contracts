pragma solidity ^0.8;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IRegistry.sol";
import "../interfaces/IStakeManager.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IForwarder.sol";
import "./abstract/Shared.sol";


contract Registry is IRegistry, Shared, ReentrancyGuard {
    
    // Constant public
    uint public constant GAS_OVERHEAD_AUTO = 16000;
    uint public constant GAS_OVERHEAD_ETH = 6000;
    uint public constant BASE_BPS = 10000;
    uint public constant PAY_AUTO_BPS = 11000;
    uint public constant PAY_ETH_BPS = 13000;

    // Constant private
    bytes private constant _EMPTY_BYTES = "";
    
    IERC20 private immutable _AUTO;
    IStakeManager private immutable _stakeMan;
    IOracle private immutable _oracle;
    IForwarder private immutable _userForwarder;
    IForwarder private immutable _gasForwarder;
    IForwarder private immutable _userGasForwarder;

    mapping(address => bool) private _invalidTargets;
    // This counts the number of times each user has had a request executed
    mapping(address => uint) private _reqCounts;
    // This counts the number of times each staker has executed a request
    mapping(address => uint) private _execCounts;
    // This counts the number of times each referer has been identified in an
    // executed tx
    mapping(address => uint) private _referalCounts;
    // We need to have 2 separete arrays for adding requests with and without
    // eth because, when comparing the hash of a request to be executed to the
    // stored hash, we have no idea what the request had for the eth values
    // that was originally stored as a hash and therefore would need to store
    // an extra bool saying where eth was sent with the new request. Instead, 
    // that can be known implicitly by having 2 separate arrays.
    bytes32[] private _hashedReqs;
    bytes32[] private _hashedReqsUnveri;
    
    
    // This is defined in IRegistry. Here for convenience
    // The address vars are 20b, total 60, calldata is 4b + n*32b usually, which
    // has a factor of 32. uint112 since the current ETH supply of ~115m can fit
    // into that and it's the highest such that 2 * uint112 + 2 * bool is < 256b
    // struct Request {
    //     address payable user;
    //     address target;
    //     address payable referer;
    //     bytes callData;
    //     uint112 initEthSent;
    //     uint112 ethForCall;
    //     bool verifyUser;
    //     bool insertFeeAmount;
    //     bool payWithAUTO;
    // }

    // Easier to parse when using native types rather than structs
    event HashedReqAdded(
        uint indexed id,
        address indexed user,
        address target,
        address payable referer,
        bytes callData,
        uint112 initEthSent,
        uint112 ethForCall,
        bool verifyUser,
        bool insertFeeAmount,
        bool payWithAUTO
    );
    event HashedReqRemoved(uint indexed id, bool wasExecuted);
    event HashedReqUnveriAdded(uint indexed id);
    event HashedReqUnveriRemoved(uint indexed id, bool wasExecuted);


    constructor(
        IERC20 AUTO,
        IStakeManager stakeMan,
        IOracle oracle,
        IForwarder userForwarder,
        IForwarder gasForwarder,
        IForwarder userGasForwarder
    ) ReentrancyGuard() {
        _AUTO = AUTO;
        _stakeMan = stakeMan;
        _oracle = oracle;
        _userForwarder = userForwarder;
        _gasForwarder = gasForwarder;
        _userGasForwarder = userGasForwarder;
        _invalidTargets[address(this)] = true;
        _invalidTargets[address(userForwarder)] = true;
        _invalidTargets[address(gasForwarder)] = true;
        _invalidTargets[address(userGasForwarder)] = true;
        _invalidTargets[address(AUTO)] = true;
        _invalidTargets[0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24] = true;
    }


    //////////////////////////////////////////////////////////////
    //                                                          //
    //                      Hashed Requests                     //
    //                                                          //
    //////////////////////////////////////////////////////////////

    function newReq(
        address target,
        address payable referer,
        bytes calldata callData,
        uint112 ethForCall,
        bool verifyUser,
        bool insertFeeAmount
    ) external payable override returns (uint id) {
        return _newReq(
            target,
            referer,
            callData,
            ethForCall,
            verifyUser,
            insertFeeAmount,
            _oracle.defaultPayIsAUTO()
        );
    }

    function newReqPaySpecific(
        address target,
        address payable referer,
        bytes calldata callData,
        uint112 ethForCall,
        bool verifyUser,
        bool insertFeeAmount,
        bool payWithAUTO
    ) external payable override returns (uint id) {
        return _newReq(
            target,
            referer,
            callData,
            ethForCall,
            verifyUser,
            insertFeeAmount,
            payWithAUTO
        );
    }

    function _newReq(
        address target,
        address payable referer,
        bytes calldata callData,
        uint112 ethForCall,
        bool verifyUser,
        bool insertFeeAmount,
        bool payWithAUTO
    )
        private
        nzAddr(target)
        targetNotThis(target)
        validEth(payWithAUTO, ethForCall)
        returns (uint id)
    {
        Request memory r = Request(
            payable(msg.sender),
            target,
            referer,
            callData,
            uint112(msg.value),
            ethForCall,
            verifyUser,
            insertFeeAmount,
            payWithAUTO
        );
        bytes32 hashedIpfsReq = keccak256(getReqBytes(r));

        id = _hashedReqs.length;
        emit HashedReqAdded(
            id,
            r.user,
            r.target,
            r.referer,
            r.callData,
            r.initEthSent,
            r.ethForCall,
            r.verifyUser,
            r.insertFeeAmount,
            r.payWithAUTO
        );
        _hashedReqs.push(hashedIpfsReq);
    }

    function getHashedReqs() external view override returns (bytes32[] memory) {
        return _hashedReqs;
    }

    function getHashedReqsSlice(uint startIdx, uint endIdx) external override view returns (bytes32[] memory) {
        return _getBytes32Slice(_hashedReqs, startIdx, endIdx);
    }

    function getHashedReqsLen() external view override returns (uint) {
        return _hashedReqs.length;
    }
    
    function getHashedReq(uint id) external view override returns (bytes32) {
        return _hashedReqs[id];
    }


    //////////////////////////////////////////////////////////////
    //                                                          //
    //                Hashed Requests Unverified                //
    //                                                          //
    //////////////////////////////////////////////////////////////

    function newHashedReqUnveri(bytes32 hashedIpfsReq)
        external
        override
        nzBytes32(hashedIpfsReq)
        returns (uint id)
    {
        id = _hashedReqsUnveri.length;
        _hashedReqsUnveri.push(hashedIpfsReq);
        emit HashedReqUnveriAdded(id);
    }
    
    function getHashedReqsUnveri() external view override returns (bytes32[] memory) {
        return _hashedReqsUnveri;
    }

    function getHashedReqsUnveriSlice(uint startIdx, uint endIdx) external view override returns (bytes32[] memory) {
        return _getBytes32Slice(_hashedReqsUnveri, startIdx, endIdx);
    }

    function getHashedReqsUnveriLen() external view override returns (uint) {
        return _hashedReqsUnveri.length;
    }
    
    function getHashedReqUnveri(uint id) external view override returns (bytes32) {
        return _hashedReqsUnveri[id];
    }


    //////////////////////////////////////////////////////////////
    //                                                          //
    //                        Bytes Helpers                     //
    //                                                          //
    //////////////////////////////////////////////////////////////

    function getReqBytes(Request memory r) public pure override returns (bytes memory) {
        return abi.encode(r);
    }

    function getIpfsReqBytes(
        bytes memory r,
        bytes memory dataPrefix,
        bytes memory dataPostfix
    ) public pure override returns (bytes memory) {
        return abi.encodePacked(
            dataPrefix,
            r,
            dataPostfix
        );
    }

    function getHashedIpfsReq(
        bytes memory r,
        bytes memory dataPrefix,
        bytes memory dataPostfix
    ) public pure override returns (bytes32) {
        return sha256(getIpfsReqBytes(r, dataPrefix, dataPostfix));
    }

    function getReqFromBytes(bytes memory rBytes) public pure override returns (Request memory r) {
        (r) = abi.decode(rBytes, (Request));
    }

    function insertToCallData(bytes calldata callData, uint expectedGas, uint startIdx) public pure override returns (bytes memory) {
        bytes memory cd = callData;
        bytes memory expectedGasBytes = abi.encode(expectedGas);
        for (uint i = 0; i < 32; i++) {
            cd[startIdx+i] = expectedGasBytes[i];
        }

        return cd;
    }
    

    //////////////////////////////////////////////////////////////
    //                                                          //
    //                         Executions                       //
    //                                                          //
    //////////////////////////////////////////////////////////////


    /**
     * @dev validCalldata needs to be before anything that would convert it to memory
     *      since that is persistent and would prevent validCalldata, that requries
     *      calldata, from working. Can't do the check in _execute for the same reason.
     *      Note: targetNotThis and validEth are used in newReq.
     *      validCalldata is only used here because it causes an unknown
     *      'InternalCompilerError' when using it with newReq
     */
    function executeHashedReq(
        uint id,
        Request calldata r,
        uint expectedGas
    )
        external
        override
        validExec
        nonReentrant
        validCalldata(r)
        verReq(id, r)
        returns (uint gasUsed)
    {
        uint startGas = gasleft();

        delete _hashedReqs[id];
        _execute(r, expectedGas);
        emit HashedReqRemoved(id, true);

        gasUsed = startGas - gasleft();
        gasUsed += r.payWithAUTO == true ? GAS_OVERHEAD_AUTO : GAS_OVERHEAD_ETH;
        // Make sure that the expected gas used is within 10% of the actual gas used
        require(expectedGas * 10 <= gasUsed * 11, "Reg: expectedGas too high");
    }

    function executeHashedReqUnveri(
        uint id,
        Request calldata r,
        bytes memory dataPrefix,
        bytes memory dataSuffix,
        uint expectedGas
    )
        external
        override
        validExec
        nonReentrant
        targetNotThis(r.target)
        verReqIPFS(id, r, dataPrefix, dataSuffix)
        returns (uint gasUsed)
    {
        uint startGas = gasleft();
        require(
            r.initEthSent == 0 &&
            r.ethForCall == 0 &&
            r.payWithAUTO == true &&
            r.verifyUser == false,
            "Reg: cannot verify. Nice try ;)"
        );

        delete _hashedReqsUnveri[id];
        _execute(r, expectedGas);
        emit HashedReqUnveriRemoved(id, true);

        gasUsed = startGas - gasleft();
        gasUsed += r.payWithAUTO == true ? GAS_OVERHEAD_AUTO : GAS_OVERHEAD_ETH;
        // Make sure that the expected gas used is within 10% of the actual gas used
        require(expectedGas * 10 <= gasUsed * 11, "Reg: expectedGas too high");
    }

    function _execute(Request calldata r, uint expectedGas) private {
        IOracle orac = _oracle;
        uint ethStartBal = address(this).balance;
        uint feeTotal;
        if (r.payWithAUTO) {
            feeTotal = expectedGas * orac.getGasPriceFast() * orac.getAUTOPerETH() * PAY_AUTO_BPS / (BASE_BPS * _E_18);
        } else {
            feeTotal = expectedGas * orac.getGasPriceFast() * PAY_ETH_BPS / BASE_BPS;
        }

        // Make the call that the user requested
        bool success;
        bytes memory returnData;
        if (r.verifyUser && !r.insertFeeAmount) {
            (success, returnData) = _userForwarder.forward{value: r.ethForCall}(r.target, r.callData);
        } else if (!r.verifyUser && r.insertFeeAmount) {
            (success, returnData) = _gasForwarder.forward{value: r.ethForCall}(
                r.target,
                insertToCallData(r.callData, feeTotal, 4)
            );
        } else if (r.verifyUser && r.insertFeeAmount) {
            (success, returnData) = _userGasForwarder.forward{value: r.ethForCall}(
                r.target,
                insertToCallData(r.callData, feeTotal, 36)
            );
        } else {
            (success, returnData) = r.target.call{value: r.ethForCall}(r.callData);
        }
        // Need this if statement because if the call succeeds, the tx will revert
        // with an EVM error because it can't decode 0x00. If a tx fails with no error
        // message, maybe that's a problem? But if it failed without a message then it's
        // gonna be hard to know what went wrong regardless
        if (!success) {
            revert(abi.decode(returnData, (string)));
        }
        
        // Store AUTO rewards
        // It's cheaper to store the cumulative rewards than it is to send
        // an AUTO transfer directly since the former changes 1 storage
        // slot whereas the latter changes 2. The rewards are actually stored
        // in a different contract that reads the reward storage of this contract
        // because of the danger of someone using call to call to AUTO and transfer
        // out tokens. It could be prevented by preventing r.target being set to AUTO,
        // but it's better to be paranoid and totally separate the contracts.
        // Need to include these storages in the gas cost that the user pays since
        // they benefit from part of it and the costs can vary depending on whether
        // the amounts changed from were 0 or non-0
        _reqCounts[r.user] += 1;
        _execCounts[msg.sender] += 1;
        if (r.referer != _ADDR_0) {
            _referalCounts[r.referer] += 1;
        }

        // If ETH was somehow siphoned from this contract during the request,
        // this will revert because of an `Integer overflow` underflow - a security feature
        uint ethReceivedDuringRequest = address(this).balance + r.ethForCall - ethStartBal;
        if (r.payWithAUTO) {
            // Send the executor their bounty
            require(_AUTO.transferFrom(r.user, msg.sender, feeTotal));
        } else {
            uint ethReceived = r.initEthSent - r.ethForCall + ethReceivedDuringRequest;
            // Send the executor their bounty
            require(ethReceived >= feeTotal, "Reg: not enough eth sent");
            payable(msg.sender).transfer(feeTotal);

            // Refund excess to the user
            uint excess = ethReceived - feeTotal;
            if (excess > 0) {
                r.user.transfer(excess);
            }
        }
    }

    //////////////////////////////////////////////////////////////
    //                                                          //
    //                        Cancellations                     //
    //                                                          //
    //////////////////////////////////////////////////////////////
    
    
    function cancelHashedReq(
        uint id,
        Request memory r
    )
        external
        override
        nonReentrant
        verReq(id, r)
    {
        require(msg.sender == r.user, "Reg: not the user");
        
        // Cancel the request
        emit HashedReqRemoved(id, false);
        delete _hashedReqs[id];
        
        // Send refund
        if (r.initEthSent > 0) {
            r.user.transfer(r.initEthSent);
        }
    }
    
    function cancelHashedReqUnveri(
        uint id,
        Request memory r,
        bytes memory dataPrefix,
        bytes memory dataSuffix
    )
        external
        override
        nonReentrant
        verReqIPFS(id, r, dataPrefix, dataSuffix)
    {
        require(msg.sender == r.user, "Reg: not the user");
        
        // Cancel the request
        emit HashedReqUnveriRemoved(id, false);
        delete _hashedReqsUnveri[id];
    }
    
    
    //////////////////////////////////////////////////////////////
    //                                                          //
    //                          Getters                         //
    //                                                          //
    //////////////////////////////////////////////////////////////
    
    function getAUTO() external view override returns (IERC20) {
        return _AUTO;
    }
    
    function getStakeManager() external view override returns (address) {
        return address(_stakeMan);
    }
    
    function getOracle() external view override returns (address) {
        return address(_oracle);
    }
    
    function getUserForwarder() external view override returns (address) {
        return address(_userForwarder);
    }
    
    function getGasForwarder() external view override returns (address) {
        return address(_gasForwarder);
    }
    
    function getUserGasForwarder() external view override returns (address) {
        return address(_userGasForwarder);
    }

    function getReqCountOf(address addr) external view override returns (uint) {
        return _reqCounts[addr];
    }
    
    function getExecCountOf(address addr) external view override returns (uint) {
        return _execCounts[addr];
    }
    
    function getReferalCountOf(address addr) external view override returns (uint) {
        return _referalCounts[addr];
    }

    function _getBytes32Slice(bytes32[] memory arr, uint startIdx, uint endIdx) private pure returns (bytes32[] memory) {
        bytes32[] memory slice = new bytes32[](endIdx - startIdx);
        uint sliceIdx = 0;
        for (uint arrIdx = startIdx; arrIdx < endIdx; arrIdx++) {
            slice[sliceIdx] = arr[arrIdx];
            sliceIdx++;
        }

        return slice;
    }


    //////////////////////////////////////////////////////////////
    //                                                          //
    //                          Modifiers                       //
    //                                                          //
    //////////////////////////////////////////////////////////////

    modifier targetNotThis(address target) {
        require(!_invalidTargets[target], "Reg: nice try ;)");
        _;
    }

    modifier validEth(bool payWithAUTO, uint ethForCall) {
        if (payWithAUTO) {
            // When paying with AUTO, there's no reason to send more ETH than will
            // be used in the future call
            require(ethForCall == msg.value, "Reg: ethForCall not msg.value");
        } else {
            // When paying with ETH, ethForCall needs to be lower than msg.value
            // since some ETH is needed to be left over for paying the fee + bounty
            require(ethForCall <= msg.value, "Reg: ethForCall too high");
        }
        _;
    }

    modifier validCalldata(Request calldata r) {
        if (r.verifyUser) {
            require(abi.decode(r.callData[4:36], (address)) == r.user, "Reg: calldata not verified");
        }
        _;
    }

    modifier validExec() {
        require(_stakeMan.isUpdatedExec(msg.sender), "Reg: not executor or expired");
        _;
    }

    // Verify that a request is the same as the one initially stored. This also
    // implicitly checks that the request hasn't been deleted as the hash of the
    // request isn't going to be address(0)
    modifier verReq(
        uint id,
        Request memory r
    ) {
        require(
            keccak256(getReqBytes(r)) == _hashedReqs[id], 
            "Reg: request not the same"
        );
        _;
    }

    // Verify that a request is the same as the one initially stored. This also
    // implicitly checks that the request hasn't been deleted as the hash of the
    // request isn't going to be address(0)
    modifier verReqIPFS(
        uint id,
        Request memory r,
        bytes memory dataPrefix,
        bytes memory dataSuffix
    ) {
        require(
            getHashedIpfsReq(getReqBytes(r), dataPrefix, dataSuffix) == _hashedReqsUnveri[id], 
            "Reg: unveri request not the same"
        );
        _;
    }
    
    receive() external payable {}
}
