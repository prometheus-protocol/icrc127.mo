// packages/canisters/icrc127/test/icrc127.pic.test.ts
import * as path from 'node:path';
import { Principal } from "@dfinity/principal";
import { IDL } from "@dfinity/candid";
import { PocketIc, createIdentity } from "@dfinity/pic";
import type { Actor } from "@dfinity/pic";
import type { Identity } from '@dfinity/agent';

// Import from the main ICRC-127 test canister's declarations
import { idlFactory as icrc127IdlFactory, init as icrc127Init } from "../../src/declarations/main/main.did.js";
import type { _SERVICE as Icrc127Service, CreateBountyRequest, BountySubmissionRequest, GetBlocksResult, Value } from "../../src/declarations/main/main.did.js";

// --- Constants and Setup ---
const ICRC127_WASM_PATH = path.resolve(__dirname, "../../.dfx/local/canisters/main/main.wasm");

let pic: PocketIc;
let bountyCanister: Actor<Icrc127Service>;

// --- Identities ---
const daoIdentity: Identity = createIdentity("dao-principal");
const bountyCreatorIdentity: Identity = createIdentity("bounty-creator");
const bountyClaimantIdentity: Identity = createIdentity("bounty-claimant");

// --- Helper Function for ICRC-3 Block Verification ---
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

describe("ICRC-127 Bounty Library (Hook-Based Validation)", () => {
  let bountyId: bigint;
  let bountyCanisterId: Principal;

  beforeAll(async () => {
    pic = await PocketIc.create(process.env.PIC_URL);

    pic.setTime(new Date());
    pic.tick();

    // Deploy the main ICRC-127 host canister (NO mock validator needed)
    const bountyFixture = await pic.setupCanister<Icrc127Service>({
      sender: daoIdentity.getPrincipal(),
      idlFactory: icrc127IdlFactory,
      wasm: ICRC127_WASM_PATH,
      arg: IDL.encode(icrc127Init({ IDL }), [{ icrc127Args: [], ttArgs: [] }]),
    });
    bountyCanister = bountyFixture.actor;
    bountyCanisterId = bountyFixture.canisterId;

    // Set up funds for the bounty creator
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
      // This ID is now just for reference, not for an inter-canister call.
      validation_canister_id: Principal.fromText("aaaaa-aa"),
      timeout_date: BigInt(Date.now() + 86400000) * 1_000_000n,
      start_date: [],
      challenge_parameters: { Text: "secret_code_123" },
      bounty_metadata: [
        ['icrc127:reward_canister', { Principal: bountyCanisterId }],
        ['icrc127:reward_amount', { Nat: bountyAmount }],
      ],
    };

    const result = await bountyCanister.icrc127_create_bounty(createRequest);
    // @ts-ignore
    expect(result.Ok).toBeDefined();

    if (!('Ok' in result)) {
      throw new Error("Bounty creation failed");
    }
    
    bountyId = result.Ok.bounty_id;

    const creatorBalance = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
    expect(creatorBalance).toBe(500_000n);
  });

  it('should REJECT a claim with incorrect submission data', async () => {
    bountyCanister.setIdentity(bountyClaimantIdentity);
    const submissionRequest: BountySubmissionRequest = {
      bounty_id: bountyId,
      submission: { Text: "wrong_code" },
      account: [],
    };
    const result = await bountyCanister.icrc127_submit_bounty(submissionRequest);
    if (!('Ok' in result)) {
      throw new Error("Bounty submission failed");
    }
    // Expect the result to indicate an invalid submission
    if (!result.Ok || !result.Ok.result || !result.Ok.result[0] || !result.Ok.result[0].result) {
      throw new Error("Unexpected result structure");
    }
    expect(result.Ok?.result?.[0].result).toHaveProperty('Invalid');
  });

  it('should ACCEPT a claim with correct submission data and transfer funds', async () => {
    bountyCanister.setIdentity(bountyClaimantIdentity);
    const submissionRequest: BountySubmissionRequest = {
      bounty_id: bountyId,
      submission: { Text: "secret_code_123" },
      account: [],
    };
    const result = await bountyCanister.icrc127_submit_bounty(submissionRequest);
    if (!('Ok' in result)) {
      throw new Error("Bounty submission failed");
    }
    // Expect the result to indicate a valid submission
    if (!result.Ok || !result.Ok.result || !result.Ok.result[0] || !result.Ok.result[0].result) {
      throw new Error("Unexpected result structure");
    }
    expect(result.Ok?.result?.[0].result).toHaveProperty('Valid');

    const claimantBalance = await bountyCanister.get_balance(bountyClaimantIdentity.getPrincipal());
    expect(claimantBalance).toBe(500_000n);
  });

  // --- NEW TESTS FOR ICRC-3 LOGGING ---

  it('should log a `127bounty` block to ICRC-3 upon creation', async () => {
    // ARRANGE: A new bounty
    bountyCanister.setIdentity(bountyCreatorIdentity);
    const createRequest: CreateBountyRequest = {
      bounty_id: [],
      validation_canister_id: Principal.fromText("aaaaa-aa"),
      timeout_date: BigInt(Date.now() + 86400000) * 1_000_000n,
      start_date: [],
      challenge_parameters: { Text: "log_test_challenge" },
      bounty_metadata: [
        ['icrc127:reward_canister', { Principal: bountyCanisterId }],
        ['icrc127:reward_amount', { Nat: 100n }],
      ],
    };
    await bountyCanister.icrc127_create_bounty(createRequest);

    // ACT: Query the logs
    const logResult = await bountyCanister.icrc3_get_blocks([{ start: 0n, length: 100n }]);
    const txData = findBlock(logResult, '127bounty');

    // ASSERT
    expect(txData).toBeDefined();
    const callerEntry = txData?.find(([key]) => key === 'caller');
    expect(callerEntry?.[1]).toEqual({ Text: bountyCreatorIdentity.getPrincipal().toText() });
    const challengeEntry = txData?.find(([key]) => key === 'challenge_params');
    expect(challengeEntry?.[1]).toEqual({ Text: "log_test_challenge" });
  });

  it('should log `127submit_bounty` and `127bounty_run` blocks on a claim attempt', async () => {
    // ACT: Submit the claim (this is the action we are testing)
    bountyCanister.setIdentity(bountyClaimantIdentity);
    const submissionRequest: BountySubmissionRequest = {
      bounty_id: bountyId,
      submission: { Text: "secret_code_123" },
      account: [],
    };
    await bountyCanister.icrc127_submit_bounty(submissionRequest);

    // ASSERT: Query the logs and find both blocks
    const logResult = await bountyCanister.icrc3_get_blocks([{ start: 0n, length: 100n }]);

    // Verify the '127submit_bounty' block
    const submitTxData = findBlock(logResult, '127submit_bounty');
    expect(submitTxData).toBeDefined();
    const submitBountyId = submitTxData?.find(([key]) => key === 'bounty_id');
    expect(submitBountyId?.[1]).toEqual({ Nat: bountyId });
    const submitCaller = submitTxData?.find(([key]) => key === 'caller');
    expect(submitCaller?.[1]).toEqual({ Text: bountyClaimantIdentity.getPrincipal().toText() });

    // Verify the '127bounty_run' block
    const runTxData = findBlock(logResult, '127bounty_run');
    expect(runTxData).toBeDefined();
    const runBountyId = runTxData?.find(([key]) => key === 'bounty_id');
    expect(runBountyId?.[1]).toEqual({ Nat: bountyId });
    const runResult = runTxData?.find(([key]) => key === 'result');
    expect(runResult?.[1]).toEqual({ Text: 'Valid' });
  });

  describe('Bounty Expiration', () => {
    it('should expire an unclaimed bounty and refund the creator', async () => {
      // ARRANGE: Create a new bounty with a short timeout
      bountyCanister.setIdentity(bountyCreatorIdentity);
      const bountyAmount = 250_000n;
      const timeoutMs = 5_000; // 5 seconds
      const timeoutNano = BigInt(Date.now() + timeoutMs) * 1_000_000n;

      const createRequest: CreateBountyRequest = {
        bounty_id: [],
        validation_canister_id: Principal.fromText("aaaaa-aa"),
        timeout_date: timeoutNano,
        start_date: [],
        challenge_parameters: { Text: "expire_me" },
        bounty_metadata: [
          ['icrc127:reward_canister', { Principal: bountyCanisterId }],
          ['icrc127:reward_amount', { Nat: bountyAmount }],
        ],
      };
      const createResult = await bountyCanister.icrc127_create_bounty(createRequest);
      if (!('Ok' in createResult)) throw new Error("Bounty creation for expiration test failed");
      const expirationBountyId = createResult.Ok.bounty_id;

      const initialBalance = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());

      // ACT: Advance time past the expiration date
      await pic.advanceTime(timeoutMs + 1000); // Advance 6 seconds
      await pic.tick(2); // Allow timers and async calls to process

      // ASSERT
      // 1. Check for refund
      const finalBalance = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
      expect(finalBalance).toBe(initialBalance + bountyAmount);

      // 2. Check that the bounty is gone from state
      const expiredBounty = await bountyCanister.icrc127_get_bounty(expirationBountyId);
      expect(expiredBounty).toEqual([]);

      // 3. Check for the log entry
      const logResult = await bountyCanister.icrc3_get_blocks([{ start: 0n, length: 100n }]);
      const txData = findBlock(logResult, '127bounty_expired');
      expect(txData).toBeDefined();
      const loggedBountyId = txData?.find(([key]) => key === 'bounty_id');
      expect(loggedBountyId?.[1]).toEqual({ Nat: expirationBountyId });
    });

    it('should cancel the expiration timer when a bounty is claimed', async () => {
      // ARRANGE: Create another bounty with a short timeout
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
        bounty_metadata: [
          ['icrc127:reward_canister', { Principal: bountyCanisterId }],
          ['icrc127:reward_amount', { Nat: bountyAmount }],
        ],
      };
      const createResult = await bountyCanister.icrc127_create_bounty(createRequest);
      if (!('Ok' in createResult)) throw new Error("Bounty creation for cancellation test failed");
      const cancellationBountyId = createResult.Ok.bounty_id;

      const creatorBalanceAfterCreation = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());

      // ACT: Claim the bounty *before* it expires
      bountyCanister.setIdentity(bountyClaimantIdentity);
      const submissionRequest: BountySubmissionRequest = {
        bounty_id: cancellationBountyId,
        submission: { Text: "claim_me_quick" },
        account: [],
      };
      const res = await bountyCanister.icrc127_submit_bounty(submissionRequest);
      console.log("Claim result:", res);

      // Now, advance time past the original expiration date
      await pic.advanceTime(timeoutDurationMs + 1000);
      await pic.tick(2);

      // ASSERT
      // 1. The creator's balance should NOT have been refunded.
      const creatorBalanceAfterTimeout = await bountyCanister.get_balance(bountyCreatorIdentity.getPrincipal());
      expect(creatorBalanceAfterTimeout).toBe(creatorBalanceAfterCreation);

      // 2. The bounty should still exist, but be marked as claimed.
      const claimedBounty = await bountyCanister.icrc127_get_bounty(cancellationBountyId);
      expect(claimedBounty).toBeDefined();
      expect(claimedBounty?.[0]?.claimed).not.toEqual([]);
    });
  });
});