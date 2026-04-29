// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// 用来验证 swap-and-pop 三种遍历写法的差异
contract SwapPopTest {
    struct Item {
        uint256 amount;
        uint256 unlockBlock;
    }

    Item[] public items;
    uint256 public lastWithdrawn;

    function push(uint256 amount, uint256 unlockBlock) external {
        items.push(Item({amount: amount, unlockBlock: unlockBlock}));
    }

    function length() external view returns (uint256) {
        return items.length;
    }

    function getAmounts() external view returns (uint256[] memory) {
        uint256[] memory out = new uint256[](items.length);
        for (uint256 i = 0; i < items.length; i++) {
            out[i] = items[i].amount;
        }
        return out;
    }

    // 错误版：从前往后 + swap-and-pop + i++（会漏处理被换过来的元素）
    function withdrawBuggy(uint256 currentBlock) external {
        uint256 withdrawn = 0;
        for (uint256 i = 0; i < items.length; i++) {
            if (currentBlock >= items[i].unlockBlock) {
                withdrawn += items[i].amount;
                items[i] = items[items.length - 1];
                items.pop();
            }
        }
        lastWithdrawn = withdrawn;
    }

    // 正确版 1：从后往前
    function withdrawReverse(uint256 currentBlock) external {
        uint256 withdrawn = 0;
        for (uint256 i = items.length; i > 0; i--) {
            uint256 idx = i - 1;
            if (currentBlock >= items[idx].unlockBlock) {
                withdrawn += items[idx].amount;
                items[idx] = items[items.length - 1];
                items.pop();
            }
        }
        lastWithdrawn = withdrawn;
    }

    // 正确版 2：从前往后但命中时不自增
    function withdrawNoIncrement(uint256 currentBlock) external {
        uint256 withdrawn = 0;
        uint256 i = 0;
        while (i < items.length) {
            if (currentBlock >= items[i].unlockBlock) {
                withdrawn += items[i].amount;
                items[i] = items[items.length - 1];
                items.pop();
            } else {
                i++;
            }
        }
        lastWithdrawn = withdrawn;
    }
}
