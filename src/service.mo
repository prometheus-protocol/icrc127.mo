// libs/icrc127/src/service.mo
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";

// This service file is a direct Motoko translation of the ICRC-127 specification.
module {

  // --- ICRC-16 Generic Data Type ---
  // A comprehensive definition to support flexible metadata.
  public type ICRC16Property = { name : Text; value : ICRC16; immutable : Bool };
  public type ICRC16 = {
    #Array : [ICRC16];
    #Blob : Blob;
    #Bool : Bool;
    #Bytes : [Nat8];
    #Class : [ICRC16Property];
    #Float : Float;
    #Floats : [Float];
    #Int : Int;
    #Int16 : Int16;
    #Int32 : Int32;
    #Int64 : Int64;
    #Int8 : Int8;
    #Map : ICRC16Map;
    #ValueMap : [(ICRC16, ICRC16)];
    #Nat : Nat;
    #Nat16 : Nat16;
    #Nat32 : Nat32;
    #Nat64 : Nat64;
    #Nat8 : Nat8;
    #Nats : [Nat];
    #Option : ?ICRC16;
    #Principal : Principal;
    #Set : [ICRC16];
    #Text : Text;
  };
  public type ICRC16Map = [(Text, ICRC16)];

  // --- ICRC-1 Account ---
  public type Account = { owner : Principal; subaccount : ?Blob };

  // --- Core ICRC-127 Types ---

  public type RunBountyRequest = {
    bounty_id : Nat;
    submission_id : Nat;
    submission : ICRC16;
    challenge_parameters : ICRC16;
  };

  public type RunBountyResult = {
    result : { #Valid; #Invalid };
    metadata : ICRC16;
    trx_id : ?Nat; // Corrected to snake_case
  };

  public type ClaimRecord = {
    claim_id : Nat; // Corrected to snake_case
    time_submitted : Nat; // Corrected to snake_case
    caller : Principal;
    claim_account : ?Account;
    submission : ICRC16;
    claim_metadata : ICRC16Map;
    result : ?RunBountyResult;
  };

  public type Bounty = {
    bounty_id : Nat;
    validation_canister_id : Principal;
    validation_call_timeout : Nat;
    bounty_metadata : ICRC16Map; // Corrected to snake_case
    timeout_date : ?Nat;
    claimed : ?Nat;
    claims : [ClaimRecord];
    created : Nat;
    claimed_date : ?Nat;
  };

  // --- Method-Specific Types ---

  public type CreateBountyRequest = {
    bounty_id : ?Nat;
    bounty_metadata : ICRC16Map;
    challenge_parameters : ICRC16;
    validation_canister_id : Principal;
    timeout_date : Nat;
    start_date : ?Nat;
  };

  public type CreateBountyResult = {
    #Ok : {
      bounty_id : Nat; // Corrected to snake_case
      trx_id : ?Nat; // Corrected to snake_case
    };
    #Error : {
      #InsufficientAllowance;
      #Generic : Text;
    };
  };

  public type BountySubmissionRequest = {
    bounty_id : Nat;
    submission : ICRC16;
    account : ?Account;
  };

  public type BountySubmissionResult = {
    #Ok : {
      claim_id : Nat; // Corrected to snake_case
      result : ?RunBountyResult;
    };
    #Error : {
      #NoMatch;
      #Generic : Text;
    };
  };

  public type ListBountiesFilter = {
    #claimed : Bool;
    #claimed_by : Account;
    #created_after : Nat;
    #created_before : Nat;
    #validation_canister : Principal;
    #metadata : ICRC16Map;
  };

  // --- Bounty Canister Service Interface ---
  public type Service = actor {
    icrc127_create_bounty : (CreateBountyRequest) -> async CreateBountyResult;
    icrc127_submit_bounty : (BountySubmissionRequest) -> async BountySubmissionResult;
    icrc127_get_bounty : (bounty_id : Nat) -> async ?Bounty;
    icrc127_list_bounties : (filter : ?[ListBountiesFilter], prev : ?Nat, take : ?Nat) -> async [Bounty];
    icrc127_metadata : () -> async ICRC16Map;
    icrc10_supported_standards : () -> async [{ name : Text; url : Text }];
  };

  // --- Validation Canister Service Interface ---
  // This is the interface our `mcp_registry` will need to implement.
  public type ValidationService = actor {
    icrc127_run_bounty : (RunBountyRequest) -> async RunBountyResult;
  };
};
