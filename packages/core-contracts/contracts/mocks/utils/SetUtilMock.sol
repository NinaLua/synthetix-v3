//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../utils/SetUtil.sol";

contract Bytes32SetMock {
    using SetUtil for SetUtil.Bytes32Set;

    SetUtil.Bytes32Set private _set;

    function add(bytes32 value) external {
        _set.add(value);
    }

    function remove(bytes32 value) external {
        _set.remove(value);
    }

    function contains(bytes32 value) external view returns (bool) {
        return _set.contains(value);
    }

    function length() external view returns (uint) {
        return _set.length();
    }

    function valueAt(uint position) external view returns (bytes32) {
        return _set.valueAt(position);
    }

    function positionOf(bytes32 value) external view returns (uint) {
        return _set.positionOf(value);
    }

    function values() external view returns (bytes32[] memory) {
        return _set.values();
    }
}

contract AddressSetMock {
    using SetUtil for SetUtil.AddressSet;

    SetUtil.AddressSet private _set;

    function add(address value) external {
        _set.add(value);
    }

    function remove(address value) external {
        _set.remove(value);
    }

    function contains(address value) external view returns (bool) {
        return _set.contains(value);
    }

    function length() external view returns (uint) {
        return _set.length();
    }

    function valueAt(uint position) external view returns (address) {
        return _set.valueAt(position);
    }

    function positionOf(address value) external view returns (uint) {
        return _set.positionOf(value);
    }

    function values() external view returns (address[] memory) {
        return _set.values();
    }
}
