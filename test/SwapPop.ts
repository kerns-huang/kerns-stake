import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";

describe("SwapPopTest", async function () {
  const { viem } = await network.connect();

  // 当前"区块号"阈值：item.unlockBlock <= NOW 视为已解锁
  const NOW = 100n;
  const UNLOCKED = 50n;
  const LOCKED = 200n;

  async function deployWith(unlocks: bigint[]) {
    const c = await viem.deployContract("SwapPopTest");
    for (let i = 0; i < unlocks.length; i++) {
      await c.write.push([BigInt(i + 1), unlocks[i]]);
    }
    return c;
  }

  it("buggy 版：四个全已解锁，会漏处理（这是要证明的 bug）", async function () {
    const c = await deployWith([UNLOCKED, UNLOCKED, UNLOCKED, UNLOCKED]);
    await c.write.withdrawBuggy([NOW]);

    const remaining = await c.read.length();
    const withdrawn = await c.read.lastWithdrawn();

    // 期望全部清空、取走 1+2+3+4=10，但 buggy 实现会留下 2 个、只取走 1+2=3
    // 推演：i=0 处理 A=1，把 D 换来；i=1 处理 B=2，把 C 换来；i=2 退出（被换来的 D 和 C 漏掉）
    assert.equal(remaining, 2n, "buggy 版应当残留 2 个未处理元素");
    assert.equal(withdrawn, 3n, "buggy 版只能取走 1+2=3，被换过来的 D 和 C 漏掉");
  });

  it("reverse 版：四个全已解锁应全部清空、全部累加", async function () {
    const c = await deployWith([UNLOCKED, UNLOCKED, UNLOCKED, UNLOCKED]);
    await c.write.withdrawReverse([NOW]);

    assert.equal(await c.read.length(), 0n);
    assert.equal(await c.read.lastWithdrawn(), 1n + 2n + 3n + 4n);
  });

  it("noIncrement 版：四个全已解锁应全部清空、全部累加", async function () {
    const c = await deployWith([UNLOCKED, UNLOCKED, UNLOCKED, UNLOCKED]);
    await c.write.withdrawNoIncrement([NOW]);

    assert.equal(await c.read.length(), 0n);
    assert.equal(await c.read.lastWithdrawn(), 1n + 2n + 3n + 4n);
  });

  it("混合场景 [解, 锁, 解, 锁]：reverse 只累加 1+3，剩 2 和 4", async function () {
    const c = await deployWith([UNLOCKED, LOCKED, UNLOCKED, LOCKED]);
    await c.write.withdrawReverse([NOW]);

    assert.equal(await c.read.lastWithdrawn(), 1n + 3n);

    const amounts = (await c.read.getAmounts()) as readonly bigint[];
    const sorted = [...amounts].sort();
    assert.deepEqual(sorted, [2n, 4n]);
  });

  it("混合场景 [解, 锁, 解, 锁]：noIncrement 同样只累加 1+3，剩 2 和 4", async function () {
    const c = await deployWith([UNLOCKED, LOCKED, UNLOCKED, LOCKED]);
    await c.write.withdrawNoIncrement([NOW]);

    assert.equal(await c.read.lastWithdrawn(), 1n + 3n);

    const amounts = (await c.read.getAmounts()) as readonly bigint[];
    const sorted = [...amounts].sort();
    assert.deepEqual(sorted, [2n, 4n]);
  });

  it("混合场景 [锁, 锁, 锁, 解]：reverse 命中点 idx==length-1，剩 1/2/3", async function () {
    const c = await deployWith([LOCKED, LOCKED, LOCKED, UNLOCKED]);
    await c.write.withdrawReverse([NOW]);

    assert.equal(await c.read.lastWithdrawn(), 4n);

    const amounts = (await c.read.getAmounts()) as readonly bigint[];
    const sorted = [...amounts].sort();
    assert.deepEqual(sorted, [1n, 2n, 3n]);
  });

  it("混合场景 [解, 锁, 锁, 锁]：reverse 命中点 idx<length-1，剩 2/3/4", async function () {
    const c = await deployWith([UNLOCKED, LOCKED, LOCKED, LOCKED]);
    await c.write.withdrawReverse([NOW]);

    assert.equal(await c.read.lastWithdrawn(), 1n);

    const amounts = (await c.read.getAmounts()) as readonly bigint[];
    const sorted = [...amounts].sort();
    assert.deepEqual(sorted, [2n, 3n, 4n]);
  });
});
