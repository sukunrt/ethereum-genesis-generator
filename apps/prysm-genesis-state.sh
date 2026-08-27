#!/bin/bash -e
# Drop-in replacement for the genesis generator's eth-genesis-state-generator.
#
# Why: upstream's tool tops out at a Gloas-shaped BeaconState, and even that
# state does not match this fork's containers ("failed to unmarshal state,
# detected fork=gloas: invalid ssz encoding"). Genesis here is Heze and
# nothing upgrades into Heze, so prysmctl has to build the state.
#
# The Dockerfile installs this at /usr/local/bin/eth-genesis-state-generator
# so the stock /work/entrypoint.sh keeps working unmodified. We accept the
# same flags, ignore the ones that do not apply, and write the same two
# outputs: the SSZ state and a parsedConsensusGenesis.json carrying the four
# fields the entrypoint reads back out of it.
#
# CONTRACT: /usr/local/bin/prysmctl must be built from the matching
# decoupled-fork Prysm tree. The Dockerfile builds it from the pinned
# PRYSM_SHA; a downstream image may COPY a locally built one over it.
#
# The validator keystores come from eth2-val-tools over the mnemonic, so the
# genesis registry has to hold exactly those pubkeys in that order; we feed
# prysmctl a deposit_data.json for the same mnemonic rather than its
# deterministic interop keys.

config=""
eth1=""
ssz=""
json_out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) config="$2"; shift 2 ;;
        --eth1-config) eth1="$2"; shift 2 ;;
        --state-output) ssz="$2"; shift 2 ;;
        --json-output) json_out="$2"; shift 2 ;;
        --mnemonics|--additional-validators|--shadow-fork-block|--shadow-fork-rpc)
            echo "prysm-genesis-state: ignoring $1 $2" >&2; shift 2 ;;
        beaconchain) shift ;;
        *) echo "prysm-genesis-state: ignoring $1" >&2; shift ;;
    esac
done
: "${config:?--config is required}"
: "${eth1:?--eth1-config is required}"
: "${ssz:?--state-output is required}"

fork="${PRYSM_GENESIS_FORK:-heze}"
echo "prysm-genesis-state: building a $fork genesis state with prysmctl"

# geth's ToBlock falls back to params.InitialBaseFee when baseFeePerGas is
# absent, which is what the EL clients' "geth init" will do; prysmctl refuses
# to guess. Writing that same value in leaves the genesis block hash alone.
if [ "$(jq -r '.baseFeePerGas // "null"' "$eth1")" = "null" ]; then
    jq '.baseFeePerGas = "0x3b9aca00"' "$eth1" > "$eth1.tmp"
    mv "$eth1.tmp" "$eth1"
fi

deposits=$(mktemp)
val_tools_args=(
    --as-json-list
    --source-min 0
    --source-max "$NUMBER_OF_VALIDATORS"
    --fork-version "$GENESIS_FORK_VERSION"
    --withdrawal-credentials-type "${WITHDRAWAL_TYPE:-0x00}"
    --validators-mnemonic "$EL_AND_CL_MNEMONIC"
    --amount "${VALIDATOR_BALANCE:-32000000000}"
)
if [ "${WITHDRAWAL_TYPE:-0x00}" = "0x00" ]; then
    val_tools_args+=(--withdrawals-mnemonic "$EL_AND_CL_MNEMONIC")
else
    val_tools_args+=(--withdrawal-address "$WITHDRAWAL_ADDRESS")
fi
# eth2-val-tools names the deposit amount "value"; prysmctl wants "amount".
/usr/local/bin/eth2-val-tools deposit-data "${val_tools_args[@]}" \
    | jq '[.[] | {pubkey, withdrawal_credentials, signature,
                  deposit_data_root, amount: .value}]' > "$deposits"

# Builder registry entries. prysmctl splits 0xB0-credential deposits out of the
# same file before ProcessPreGenesisDeposits, so a builder is one extra deposit
# entry, not an extra validator: NUMBER_OF_VALIDATORS stays the validator count.
# The default index is NUMBER_OF_VALIDATORS, which is what a buildoor instance
# derives (builder_key_start_index + 0) when the package's builder_count is 0.
#
# The credential prefix is inside the deposit signature, so a wrong one cannot
# be fixed after the fact; this image's eth2-val-tools (>= 6.2.x) emits 0xb0.
if [ "${BUILDER_COUNT:-0}" -gt 0 ]; then
    builder_index=${BUILDER_KEY_INDEX:-$NUMBER_OF_VALIDATORS}
    # NOT $WITHDRAWAL_ADDRESS: the entrypoint rewrites it to the string "null"
    # whenever WITHDRAWAL_TYPE is 0x00, and eth2-val-tools rejects that.
    builder_addr=${BUILDER_EXEC_ADDR:-}
    case "$builder_addr" in
        ""|null) echo "prysm-genesis-state: BUILDER_EXEC_ADDR is unset" >&2; exit 1 ;;
    esac
    builder_deposits=$(mktemp)
    /usr/local/bin/eth2-val-tools deposit-data \
        --as-json-list \
        --source-min "$builder_index" \
        --source-max "$((builder_index + BUILDER_COUNT))" \
        --fork-version "$GENESIS_FORK_VERSION" \
        --withdrawal-credentials-type 0xb0 \
        --withdrawal-address "$builder_addr" \
        --amount "${BUILDER_DEPOSIT_GWEI:-1000000000000}" \
        --validators-mnemonic "$EL_AND_CL_MNEMONIC" \
        | jq '[.[] | {pubkey, withdrawal_credentials, signature,
                      deposit_data_root, amount: .value}]' > "$builder_deposits"
    echo "prysm-genesis-state: minted $(jq length "$builder_deposits") builder deposit(s) at index $builder_index"
    jq -r '.[] | "prysm-genesis-state: builder pubkey \(.pubkey) creds \(.withdrawal_credentials)"' \
        "$builder_deposits"
    jq -s 'add' "$deposits" "$builder_deposits" > "$deposits.tmp"
    mv "$deposits.tmp" "$deposits"
fi

# Kept next to the SSZ instead of a mktemp, so the registry is inspectable from
# outside the container: it lands in /data/metadata and rides the
# el_cl_genesis_data artifact.
state_json="${ssz%.ssz}-state.json"
/usr/local/bin/prysmctl testnet generate-genesis \
    --fork "$fork" \
    --num-validators "$NUMBER_OF_VALIDATORS" \
    --chain-config-file "$config" \
    --deposit-json-file "$deposits" \
    --geth-genesis-json-in "$eth1" \
    --genesis-time "$GENESIS_TIMESTAMP" \
    --genesis-time-delay "${GENESIS_DELAY:-0}" \
    --output-ssz "$ssz" \
    --output-json "$state_json"

# A wrong credential prefix produces NUMBER_OF_VALIDATORS+BUILDER_COUNT
# validators and an empty builder registry with no error anywhere, so this is a
# build-stopper rather than a log line. .builders is omitempty, so a baseline
# state reads 0 == 0 and passes.
n=$(jq '.builders | length' "$state_json")
[ "$n" = "${BUILDER_COUNT:-0}" ] || {
    echo "prysm-genesis-state: genesis builders=$n want ${BUILDER_COUNT:-0}" >&2; exit 1
}
echo "prysm-genesis-state: genesis builders=$n"

[ -n "$json_out" ] || exit 0

# The entrypoint reads four fields back out of the "parsed" genesis. prysm's
# JSON encodes byte fields as base64; the entrypoint's consumers want 0x-hex.
# genesis_validators_root is also taken straight from the SSZ (offset 8, right
# after the uint64 genesis_time) so a JSON shape change cannot silently break
# the value every CL client's fork digest depends on.
gvr="0x$(dd if="$ssz" bs=1 skip=8 count=32 status=none | od -An -tx1 -v \
    | tr -d ' \n')"
b64hex() {
    python3 -c 'import base64,sys; print("0x"+base64.b64decode(sys.argv[1]).hex())' "$1"
}
# prysm's JSON names the field eth_1_data, not eth1_data.
eth1_block_hash=$(b64hex "$(jq -r '.eth_1_data.block_hash // ""' "$state_json")")
# Gloas and later drop latest_execution_payload_header for latest_block_hash;
# the entrypoint only echoes these two, so a miss is cosmetic, not fatal.
payload_block_hash=$(b64hex "$(jq -r '(.latest_execution_payload_header.block_hash?)
    // .latest_block_hash // ""' "$state_json")")
payload_block_number=$(jq -r '(.latest_execution_payload_header.block_number?)
    // "0"' "$state_json")

mkdir -p "$(dirname "$json_out")"
jq -n \
    --arg gvr "$gvr" \
    --arg eth1_block_hash "$eth1_block_hash" \
    --arg block_hash "$payload_block_hash" \
    --arg block_number "$payload_block_number" \
    '{genesis_validators_root: $gvr,
      eth1_data: {block_hash: $eth1_block_hash},
      latest_execution_payload_header: {block_number: $block_number,
                                        block_hash: $block_hash}}' > "$json_out"
echo "prysm-genesis-state: genesis_validators_root $gvr"
