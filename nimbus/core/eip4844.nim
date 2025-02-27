# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, strutils],
  kzg4844/kzg_ex as kzg,
  stew/results,
  stint,
  ../constants,
  ../common/common

{.push raises: [].}

type
  Bytes32 = array[32, byte]
  Bytes64 = array[64, byte]
  Bytes48 = array[48, byte]

const
  BLS_MODULUS_STR = "52435875175126190479447740508185965837690552500527637822603658699938581184513"
  BLS_MODULUS = parse(BLS_MODULUS_STR, UInt256, 10)
  PrecompileInputLength = 192

proc pointEvaluationResult(): Bytes64 {.compileTime.} =
  result[0..<32] = FIELD_ELEMENTS_PER_BLOB.u256.toBytesBE[0..^1]
  result[32..^1] = BLS_MODULUS.toBytesBE[0..^1]

const
  PointEvaluationResult* = pointEvaluationResult()
  POINT_EVALUATION_PRECOMPILE_GAS* = 50000.GasInt


# kzgToVersionedHash implements kzg_to_versioned_hash from EIP-4844
proc kzgToVersionedHash(kzg: kzg.KZGCommitment): VersionedHash =
  result = keccakHash(kzg)
  result.data[0] = BLOB_COMMITMENT_VERSION_KZG

# pointEvaluation implements point_evaluation_precompile from EIP-4844
# return value and gas consumption is handled by pointEvaluation in
# precompiles.nim
proc pointEvaluation*(input: openArray[byte]): Result[void, string] =
  # Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
  # Also verify that the provided commitment matches the provided versioned_hash.
  # The data is encoded as follows: versioned_hash | z | y | commitment | proof |

  if input.len < PrecompileInputLength:
    return err("invalid input length")

  var
    versionedHash: Bytes32
    z: Bytes32
    y: Bytes32
    commitment: Bytes48
    kzgProof: Bytes48

  versionedHash[0..<32] = input[0..<32]
  z[0..<32] = input[32..<64]
  y[0..<32] = input[64..<96]
  commitment[0..<48] = input[96..<144]
  kzgProof[0..<48]   = input[144..<192]

  # Verify KZG proof
  let res = kzg.verifyKzgProof(commitment, z, y, kzgProof)
  if res.isErr:
    return err(res.error)

  # The actual verify result
  if not res.get():
    return err("Failed to verify KZG proof")

  ok()

# calcExcessBlobGas implements calc_excess_data_gas from EIP-4844
proc calcExcessBlobGas*(parent: BlockHeader): uint64 =
  let
    excessBlobGas = parent.excessBlobGas.get(0'u64)
    blobGasUsed = parent.blobGasUsed.get(0'u64)

  if excessBlobGas + blobGasUsed < TARGET_BLOB_GAS_PER_BLOCK:
    0'u64
  else:
    excessBlobGas + blobGasUsed - TARGET_BLOB_GAS_PER_BLOCK

# fakeExponential approximates factor * e ** (num / denom) using a taylor expansion
# as described in the EIP-4844 spec.
func fakeExponential*(factor, numerator, denominator: uint64): uint64 =
  var
    i = 1'u64
    output = 0'u64
    numeratorAccum = factor * denominator

  while numeratorAccum > 0'u64:
    output += numeratorAccum
    numeratorAccum = (numeratorAccum * numerator) div (denominator * i)
    i = i + 1'u64

  output div denominator

proc getTotalBlobGas*(tx: Transaction): uint64 =
  GAS_PER_BLOB * tx.versionedHashes.len.uint64

proc getTotalBlobGas*(versionedHashesLen: int): uint64 =
  GAS_PER_BLOB * versionedHasheslen.uint64

# getBlobGasPrice implements get_data_gas_price from EIP-4844
func getBlobGasprice*(parentExcessBlobGas: uint64): uint64 =
  fakeExponential(
    MIN_BLOB_GASPRICE,
    parentExcessBlobGas,
    BLOB_GASPRICE_UPDATE_FRACTION
  )

proc calcDataFee*(tx: Transaction,
                  parentExcessBlobGas: Option[uint64]): uint64 =
  tx.getTotalBlobGas *
    getBlobGasprice(parentExcessBlobGas.get(0'u64))

proc calcDataFee*(versionedHashesLen: int,
                  parentExcessBlobGas: Option[uint64]): uint64 =
  getTotalBlobGas(versionedHashesLen) *
    getBlobGasprice(parentExcessBlobGas.get(0'u64))

func blobGasUsed(txs: openArray[Transaction]): uint64 =
  for tx in txs:
    result += tx.getTotalBlobGas

# https://eips.ethereum.org/EIPS/eip-4844
func validateEip4844Header*(
    com: CommonRef, header, parentHeader: BlockHeader,
    txs: openArray[Transaction]): Result[void, string] {.raises: [].} =

  if not com.forkGTE(Cancun):
    if header.blobGasUsed.isSome:
      return err("unexpected EIP-4844 blobGasUsed in block header")

    if header.excessBlobGas.isSome:
      return err("unexpected EIP-4844 excessBlobGas in block header")

    return ok()

  if header.blobGasUsed.isNone:
    return err("expect EIP-4844 blobGasUsed in block header")

  if header.excessBlobGas.isNone:
    return err("expect EIP-4844 excessBlobGas in block header")

  let
    headerBlobGasUsed = header.blobGasUsed.get()
    blobGasUsed = blobGasUsed(txs)
    headerExcessBlobGas = header.excessBlobGas.get
    excessBlobGas = calcExcessBlobGas(parentHeader)

  if blobGasUsed > MAX_BLOB_GAS_PER_BLOCK:
    return err("blobGasUsed " & $blobGasUsed & " exceeds maximum allowance " & $MAX_BLOB_GAS_PER_BLOCK)

  if headerBlobGasUsed != blobGasUsed:
    return err("calculated blobGas not equal header.blobGasUsed")

  if headerExcessBlobGas != excessBlobGas:
    return err("calculated excessBlobGas not equal header.excessBlobGas")

  return ok()

proc validateBlobTransactionWrapper*(tx: Transaction):
                                     Result[void, string] {.raises: [].} =
  if not tx.networkPayload.isNil:
    return err("tx wrapper is none")

  # note: assert blobs are not malformatted
  let goodFormatted = tx.versionedHashes.len ==
                      tx.networkPayload.commitments.len and
                      tx.versionedHashes.len  ==
                      tx.networkPayload.blobs.len and
                      tx.versionedHashes.len ==
                      tx.networkPayload.proofs.len

  if not goodFormatted:
    return err("tx wrapper is ill formatted")

  # Verify that commitments match the blobs by checking the KZG proof
  let res = kzg.verifyBlobKzgProofBatch(tx.networkPayload.blobs,
              tx.networkPayload.commitments, tx.networkPayload.proofs)
  if res.isErr:
    return err(res.error)

  # Actual verification result
  if not res.get():
    return err("Failed to verify network payload of a transaction")

  # Now that all commitments have been verified, check that versionedHashes matches the commitments
  for i in 0 ..< tx.versionedHashes.len:
    # this additional check also done in tx validation
    if tx.versionedHashes[i].data[0] != BLOB_COMMITMENT_VERSION_KZG:
      return err("wrong kzg version in versioned hash at index " & $i)

    if tx.versionedHashes[i] != kzgToVersionedHash(tx.networkPayload.commitments[i]):
      return err("tx versioned hash not match commitments at index " & $i)

  ok()

proc loadKzgTrustedSetup*(): Result[void, string] =
  const
    vendorDir = currentSourcePath.parentDir.replace('\\', '/') & "/../../vendor"
    trustedSetupDir = vendorDir & "/nim-kzg4844/kzg4844/csources/src"

  const const_preset = "mainnet"
  const trustedSetup =
    when const_preset == "mainnet":
      staticRead trustedSetupDir & "/trusted_setup.txt"
    elif const_preset == "minimal":
      staticRead trustedSetupDir & "/trusted_setup_4.txt"
    else:
      ""
  if const_preset == "mainnet" or const_preset == "minimal":
    Kzg.loadTrustedSetupFromString(trustedSetup)
  else:
    ok()
