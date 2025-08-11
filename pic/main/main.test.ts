// packages/canisters/icrc127/test/icrc127.pic.test.ts
import * as path from 'node:path';
import { Principal } from "@dfinity/principal";
import { IDL } from "@dfinity/candid";
import { PocketIc, createIdentity } from "@dfinity/pic";
import type { Actor } from "@dfinity/pic";
import type { Identity } from '@dfinity/agent';

import { idlFactory as icrc127IdlFactory, init as icrc127Init } from "../../src/declarations/main/main.did.js";
import type { _SERVICE as Icrc127Service, CreateBountyRequest, BountySubmissionRequest, GetBlocksResult, Value, Bounty } from "../../src/declarations/main/main.did.js";

const ICRC127_WASM_PATH = path.resolve(__dirname, "../../.dfx/local/canisters/main/main.wasm");

const daoIdentity: Identity = createIdentity("dao-principal");
const bountyCreatorIdentity: Identity = createIdentity("bounty-creator");
const bountyClaimantIdentity: Identity = createIdentity("bounty-claimant");

function findBlock(logResult: GetBlocksResult, btype: string): [string, Value][] | undefined {
  const block = logResult.blocks.slice().reverse().find(b => {
    const blockMap = 'Map' in b.block ? b.block.Map : [];
    const btypeEntry = blockMap.find(([key, _]) => key === 'btype');
    return btypeEntry && 'Text' in btypeEntry[1] && btypeEntry[1].Text === btype;
  });
  if (!block) return undefined;
  const blockMap = 'Map' in block.block ? block.block.Map : [];
  const txEntry = blockMap.find(([key, _]) => key === 'tx');
  return txEntry && 'Map' in txEntry[1] ? txEntry[1].Map : undefined;
}

// find a value in a metadata array
function findMeta(metadata: [string, Value][], key: string): Value | undefined {
  const entry = metadata.find(([k, _]) => k === key);
  return entry?.[1];
}

// --- Test Suite 1: Core Functionality and Logging ---
describe("ICRC-127 Core Functionality", () => {
  let pic: PocketIc;
  let bountyCanister: Actor<Icrc127Service>;
  let bountyCanisterId: Principal;
  let bountyId: bigint;
  const bountyAmount = 500_000n;
  
  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL);

    pic.setTime(new Date());
    pic.tick();

    const bountyFixture = await pic.setupCanister<Icrc127Service>({
      sender: daoIdentity.getPrincipal(),
      idlFactory: icrc127IdlFactory,
      wasm: ICRC127_WASM_PATH,
      arg: IDL.encode(icrc127Init({ IDL }), [{ icrc127Args: [], ttArgs: [] }]),
    });
    bountyCanister = bountyFixture.actor;
    bountyCanisterId = bountyFixture.canisterId;

    await bountyCanister.mint(bountyCreatorIdentity.getPrincipal(), 1_000_000n);
    bountyCanister.setIdentity(bountyCreatorIdentity);
    await bountyCanister.approve(bountyFixture.canisterId, 1_000_000n);
  });

  afterAll(async () => { await pic.tearDown(); });

  it('should create a new bounty and escrow the funds', async () => {
    bountyCanister.setIdentity(bountyCreatorIdentity);
    const bountyAmount = 500_000n;
    const createRequest: CreateBountyRequest = {
      bounty_id: [],
      validation_canister_id: Principal.fromText("aaaaa-aa"),
      timeout_date: BigInt(await pic.getTime() * 1_000_000) + 86_400_000_000_000n,
      start_date: [],
      challenge_parameters: { Text: "secret_code_123" },
      bounty_metadata: [['icrc127:reward_canister', { Principal: bountyCanisterId }], ['icrc127:reward_amount', { Nat: bountyAmount }]],
    };
    const result = await bountyCanister.icrc127_create_bounty(createRequest);
    expect('Ok' in result).toBe(true);
    if (!('Ok' in result)) throw new Error("Bounty creation failed");
    bountyId = result.Ok.bounty_id;
    const creatorBalance = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
    expect(creatorBalance).toBe(500_000n);
  });

  it('should REJECT a claim with incorrect submission data', async () => {
    bountyCanister.setIdentity(bountyClaimantIdentity);
    const submissionRequest: BountySubmissionRequest = { bounty_id: bountyId, submission: { Text: "wrong_code" }, account: [] };
    const result = await bountyCanister.icrc127_submit_bounty(submissionRequest);
    expect('Ok' in result).toBe(true);
    if (!('Ok' in result)) throw new Error("Bounty submission failed");
    // @ts-ignore
    expect(result.Ok.result?.[0].result).toHaveProperty('Invalid');
  });

  it('should ACCEPT a claim with correct submission data and transfer funds', async () => {
    bountyCanister.setIdentity(bountyClaimantIdentity);
    const submissionRequest: BountySubmissionRequest = {
      bounty_id: bountyId,
      submission: { Text: "secret_code_123" },
      account: [],
    };
    const result = await bountyCanister.icrc127_submit_bounty(submissionRequest);
    expect('Ok' in result).toBe(true);
    if (!('Ok' in result)) throw new Error("Bounty submission failed");
    // @ts-ignore
    expect(result.Ok.result?.[0].result).toHaveProperty('Valid');
    const claimantBalance = await bountyCanister.get_balance(bountyClaimantIdentity.getPrincipal());
    expect(claimantBalance).toBe(bountyAmount);

    // --- ASSERT claim_metadata is populated correctly ---
    const finalBountyOpt = await bountyCanister.icrc127_get_bounty(bountyId);
    const finalBounty = finalBountyOpt[0] as Bounty; // We know it exists
    expect(finalBounty).toBeDefined();
    expect(finalBounty.claims.length).toBe(2);

    const claimRecord = finalBounty.claims[1];
    expect(claimRecord.claim_metadata.length).toBeGreaterThan(0);

    // Check for specific metadata keys from the spec
    expect(findMeta(claimRecord.claim_metadata as [string, Value][], 'icrc127:claim_amount')).toEqual({ Nat: bountyAmount });
    expect(findMeta(claimRecord.claim_metadata as [string, Value][], 'icrc127:claim_canister')).toEqual({ Principal: bountyCanisterId });
    expect(findMeta(claimRecord.claim_metadata as [string, Value][], 'icrc127:claim_token_trx_id')).toHaveProperty('Nat'); // Check it exists
  });

  it('should log `127submit_bounty` and `127bounty_run` blocks on a claim attempt', async () => {
    const logResult = await bountyCanister.icrc3_get_blocks([{ start: 0n, length: 100n }]);
    const submitTxData = findBlock(logResult, '127submit_bounty');
    expect(submitTxData).toBeDefined();
    const runTxData = findBlock(logResult, '127bounty_run');
    expect(runTxData).toBeDefined();
  });
});

// --- Test Suite 2: Bounty Expiration ---
describe('Bounty Expiration', () => {
  let pic: PocketIc;
  let bountyCanister: Actor<Icrc127Service>;
  let bountyCanisterId: Principal;

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL);
    const bountyFixture = await pic.setupCanister<Icrc127Service>({
      sender: daoIdentity.getPrincipal(),
      idlFactory: icrc127IdlFactory,
      wasm: ICRC127_WASM_PATH,
      arg: IDL.encode(icrc127Init({ IDL }), [{ icrc127Args: [], ttArgs: [] }]),
    });
    bountyCanister = bountyFixture.actor;
    bountyCanisterId = bountyFixture.canisterId;

    await bountyCanister.mint(bountyCreatorIdentity.getPrincipal(), 1_000_000n);
    bountyCanister.setIdentity(bountyCreatorIdentity);
    await bountyCanister.approve(bountyFixture.canisterId, 1_000_000n);
  });

  afterAll(async () => { await pic.tearDown(); });

  it('should expire an unclaimed bounty and refund the creator', async () => {
    bountyCanister.setIdentity(bountyCreatorIdentity);
    const bountyAmount = 250_000n;
    const timeoutDurationMs = 5_000;
    const currentTimeNano = BigInt(await pic.getTime()) * 1_000_000n;
    const timeoutNano = currentTimeNano + BigInt(timeoutDurationMs * 1_000_000);
    const createRequest: CreateBountyRequest = {
      bounty_id: [],
      validation_canister_id: Principal.fromText("aaaaa-aa"),
      timeout_date: timeoutNano,
      start_date: [],
      challenge_parameters: { Text: "expire_me" },
      bounty_metadata: [['icrc127:reward_canister', { Principal: bountyCanisterId }], ['icrc127:reward_amount', { Nat: bountyAmount }]],
    };
    const createResult = await bountyCanister.icrc127_create_bounty(createRequest);
    if (!('Ok' in createResult)) throw new Error("Bounty creation for expiration test failed");
    const expirationBountyId = createResult.Ok.bounty_id;
    const initialBalance = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
    await pic.advanceTime(timeoutDurationMs + 1000);
    await pic.tick(2);
    const finalBalance = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
    expect(finalBalance).toBe(initialBalance + bountyAmount);
    const expiredBounty = await bountyCanister.icrc127_get_bounty(expirationBountyId);
    expect(expiredBounty).toEqual([]);
  });

  it('should cancel the expiration timer when a bounty is claimed', async () => {
    bountyCanister.setIdentity(bountyCreatorIdentity);
    const bountyAmount = 150_000n;
    const timeoutDurationMs = 5_000;
    const currentTimeNano = BigInt(await pic.getTime()) * 1_000_000n;
    const timeoutNano = currentTimeNano + BigInt(timeoutDurationMs * 1_000_000);
    const createRequest: CreateBountyRequest = {
      bounty_id: [],
      validation_canister_id: Principal.fromText("aaaaa-aa"),
      timeout_date: timeoutNano,
      start_date: [],
      challenge_parameters: { Text: "claim_me_quick" },
      bounty_metadata: [['icrc127:reward_canister', { Principal: bountyCanisterId }], ['icrc127:reward_amount', { Nat: bountyAmount }]],
    };
    const createResult = await bountyCanister.icrc127_create_bounty(createRequest);
    if (!('Ok' in createResult)) throw new Error("Bounty creation for cancellation test failed");
    const cancellationBountyId = createResult.Ok.bounty_id;
    const creatorBalanceAfterCreation = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
    bountyCanister.setIdentity(bountyClaimantIdentity);
    const submissionRequest: BountySubmissionRequest = { bounty_id: cancellationBountyId, submission: { Text: "claim_me_quick" }, account: [] };
    await bountyCanister.icrc127_submit_bounty(submissionRequest);
    await pic.advanceTime(timeoutDurationMs + 1000);
    await pic.tick(2);
    const creatorBalanceAfterTimeout = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
    expect(creatorBalanceAfterTimeout).toBe(creatorBalanceAfterCreation);
    const claimedBounty = await bountyCanister.icrc127_get_bounty(cancellationBountyId);
    expect(claimedBounty).toBeDefined();
    expect(claimedBounty?.[0]?.claimed).not.toEqual([]);
  });
});

// --- Test Suite 3: Listing, Filtering, and Pagination ---
describe('icrc127_list_bounties', () => {
  let pic: PocketIc;
  let bountyCanister: Actor<Icrc127Service>;
  let bountyCanisterId: Principal;
  let bounty1_id: bigint, bounty2_id: bigint, bounty3_id: bigint;
  const creatorA_identity = createIdentity('creator-a');
  const creatorB_identity = createIdentity('creator-b');
  const claimantA_identity = createIdentity('claimant-a');

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL);

    pic.setTime(new Date());
    pic.tick();
    
    const bountyFixture = await pic.setupCanister<Icrc127Service>({
      sender: daoIdentity.getPrincipal(),
      idlFactory: icrc127IdlFactory,
      wasm: ICRC127_WASM_PATH,
      arg: IDL.encode(icrc127Init({ IDL }), [{ icrc127Args: [], ttArgs: [] }]),
    });
    bountyCanister = bountyFixture.actor;
    bountyCanisterId = bountyFixture.canisterId;

    await bountyCanister.mint(creatorA_identity.getPrincipal(), 1_000_000n);
    await bountyCanister.mint(creatorB_identity.getPrincipal(), 1_000_000n);
    const farFutureNano = BigInt(await pic.getTime() * 1_000_000) + 3_600_000_000_000n;

    bountyCanister.setIdentity(creatorA_identity);
    await bountyCanister.approve(bountyCanisterId, 1_000_000n);
    const res1 = await bountyCanister.icrc127_create_bounty({
      bounty_id: [], validation_canister_id: Principal.fromText("aaaaa-aa"), timeout_date: farFutureNano, start_date: [],
      challenge_parameters: { Text: "bounty one" }, bounty_metadata: [['tag', { Text: 'general' }], ['icrc127:reward_canister', { Principal: bountyCanisterId }], ['icrc127:reward_amount', { Nat: 500_000n }]],
    });
    bounty1_id = ('Ok' in res1 && res1.Ok.bounty_id) || 0n;

    const res2 = await bountyCanister.icrc127_create_bounty({
      bounty_id: [], validation_canister_id: Principal.fromText("aaaaa-aa"), timeout_date: farFutureNano, start_date: [],
      challenge_parameters: { Text: "bounty two" }, bounty_metadata: [['tag', { Text: 'specific' }], ['icrc127:reward_canister', { Principal: bountyCanisterId }], ['icrc127:reward_amount', { Nat: 500_000n }]],
    });
    bounty2_id = ('Ok' in res2 && res2.Ok.bounty_id) || 0n;

    bountyCanister.setIdentity(claimantA_identity);
    await bountyCanister.icrc127_submit_bounty({
      bounty_id: bounty2_id, submission: { Text: "bounty two" }, account: [{ owner: claimantA_identity.getPrincipal(), subaccount: [] }],
    });

    bountyCanister.setIdentity(creatorB_identity);
    await bountyCanister.approve(bountyCanisterId, 500_000n);
    const res3 = await bountyCanister.icrc127_create_bounty({
      bounty_id: [], validation_canister_id: bountyCanisterId, timeout_date: farFutureNano, start_date: [],
      challenge_parameters: { Text: "bounty three" }, bounty_metadata: [['tag', { Text: 'general' }], ['icrc127:reward_canister', { Principal: bountyCanisterId }], ['icrc127:reward_amount', { Nat: 500_000n }]],
    });
    bounty3_id = ('Ok' in res3 && res3.Ok.bounty_id) || 0n;
  });

  afterAll(async () => { await pic.tearDown(); });

  it('should filter by #claimed: true', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [[{ claimed: true }]], prev: [], take: [] });
    expect(result.length).toBe(1);
    expect(result[0].bounty_id).toEqual(bounty2_id);
  });

  it('should filter by #claimed: false', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [[{ claimed: false }]], prev: [], take: [] });
    expect(result.length).toBe(2);
    expect(result.map(b => b.bounty_id).sort()).toEqual([bounty1_id, bounty3_id].sort());
  });

  it('should filter by #claimed_by', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [[{ claimed_by: { owner: claimantA_identity.getPrincipal(), subaccount: [] } }]], prev: [], take: [] });
    expect(result.length).toBe(1);
    expect(result[0].bounty_id).toEqual(bounty2_id);
  });

  it('should filter by #validation_canister', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [[{ validation_canister: bountyCanisterId }]], prev: [], take: [] });
    expect(result.length).toBe(1);
    expect(result[0].bounty_id).toEqual(bounty3_id);
  });

  it('should filter by #metadata', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [[{ metadata: [['tag', { Text: 'specific' }]] }]], prev: [], take: [] });
    expect(result.length).toBe(1);
    expect(result[0].bounty_id).toEqual(bounty2_id);
  });

  it('should handle pagination with `take`', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [], prev: [], take: [2n] });
    expect(result.length).toBe(2);
    expect(result[0].bounty_id).toEqual(bounty1_id);
    expect(result[1].bounty_id).toEqual(bounty2_id);
  });

  it('should handle pagination with `prev` and `take`', async () => {
    const result = await bountyCanister.icrc127_list_bounties({ filter: [], prev: [bounty1_id], take: [1n] });
    expect(result.length).toBe(1);
    expect(result[0].bounty_id).toEqual(bounty2_id);
  });

  it('should handle combined filtering and pagination', async () => {
    const result = await bountyCanister.icrc127_list_bounties({
      filter: [[{ metadata: [['tag', { Text: 'general' }]] }]],
      prev: [bounty1_id],
      take: [1n],
    });
    expect(result.length).toBe(1);
    expect(result[0].bounty_id).toEqual(bounty3_id);
  });
});

describe('ICRC-127 Compliance and Metadata', () => {
  let pic: PocketIc;
  let bountyCanister: Actor<Icrc127Service>;

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL);
    const bountyFixture = await pic.setupCanister<Icrc127Service>({
      sender: daoIdentity.getPrincipal(),
      idlFactory: icrc127IdlFactory,
      wasm: ICRC127_WASM_PATH,
      arg: IDL.encode(icrc127Init({ IDL }), [{ icrc127Args: [], ttArgs: [] }]),
    });
    bountyCanister = bountyFixture.actor;
  });

  afterAll(async () => { await pic.tearDown(); });

  it('should return supported standards for icrc10_supported_standards', async () => {
    const standards = await bountyCanister.icrc10_supported_standards();
    expect(standards.some(s => s.name === 'ICRC-10')).toBe(true);
    expect(standards.some(s => s.name === 'ICRC-127')).toBe(true);
  });

  it('should return canister metadata for icrc127_metadata', async () => {
    const metadata = await bountyCanister.icrc127_metadata();
    // Convert ICRC16Map__1 to [string, Value][]
    const metaArr: [string, Value][] = Array.isArray(metadata) && 'Map' in metadata[0]
      ? metadata[0].Map as [string, Value][]
      : (metadata as unknown as [string, Value][]);
    const canisterType = findMeta(metaArr, 'icrc127:canister_type');
    expect(canisterType).toEqual({ Text: 'bounty' });
  });
});