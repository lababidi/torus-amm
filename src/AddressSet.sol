// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

contract AddressSet {
    // Direct storage - no struct overhead
    mapping(address => uint256) private _indices; // 1-based index, 0 = not present
    address[] private _values;

    // Cache length to avoid array access
    uint256 private _length;

    function add(address value) public returns (bool) {
        if (_indices[value] == 0) {
            _values.push(value);
            _indices[value] = _length + 1; // 1-based indexing
            _length++;
            return true;
        }
        return false;
    }

    function remove(address value) public returns (bool) {
        uint256 index = _indices[value];
        if (index == 0) return false;

        uint256 idx = index - 1;
        uint256 last = _length - 1;

        if (idx != last) {
            address lastValue = _values[last];
            _values[idx] = lastValue;
            _indices[lastValue] = idx + 1;
        }

        _values.pop();
        _length--;
        delete _indices[value];
        return true;
    }

    function contains(address value) public view returns (bool) {
        return _indices[value] != 0;
    }

    function values() public view returns (address[] memory) {
        return _values;
    }

    function length() public view returns (uint256) {
        return _length;
    }

    function isEmpty() public view returns (bool) {
        return _length == 0;
    }

    function clear() public {
        uint256 len = _length;
        for (uint256 i = 0; i < len; i++) {
            delete _indices[_values[i]];
        }
        delete _values;
        _length = 0;
    }

    function get(uint256 index) public view returns (address) {
        require(index < _length, "Index out of bounds");
        return _values[index];
    }
}
