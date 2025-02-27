# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records transaction based merge test

import
  std/[algorithm, bitops, sequtils, sets, tables],
  eth/common,
  results,
  unittest2,
  ../../nimbus/db/aristo/[
    aristo_check, aristo_delete, aristo_desc, aristo_get, aristo_merge],
  ../../nimbus/db/[aristo, aristo/aristo_init/persistent],
  ./test_helpers

type
  PrngDesc = object
    prng: uint32                       ## random state

  KnownHasherFailure* = seq[(string,(int,AristoError))]
    ## (<sample-name> & "#" <instance>, (<vertex-id>,<error-symbol>))

const
  MaxFilterBulk = 150_000
    ## Policy settig for `pack()`

  WalkStopRc =
    Result[LeafTie,(VertexID,AristoError)].err((VertexID(0),NearbyBeyondRange))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc rand[W: SomeInteger|VertexID](ap: var PrngDesc; T: type W): T =
  var a: array[sizeof T,byte]
  for n in 0 ..< sizeof T:
    a[n] = ap.prng.posixPrngRand().byte
  when sizeof(T) == 1:
    let w = uint8.fromBytesBE(a).T
  when sizeof(T) == 2:
    let w = uint16.fromBytesBE(a).T
  when sizeof(T) == 4:
    let w = uint32.fromBytesBE(a).T
  else:
    let w = uint64.fromBytesBE(a).T
  when T is SomeUnsignedInt:
    # That way, `fromBytesBE()` can be applied to `uint`
    result = w
  else:
    # That way the result is independent of endianness
    (addr result).copyMem(unsafeAddr w, sizeof w)

proc init(T: type PrngDesc; seed: int): PrngDesc =
  result.prng = (seed and 0x7fffffff).uint32

proc rand(td: var PrngDesc; top: int): int =
  if 0 < top:
    let mask = (1 shl (8 * sizeof(int) - top.countLeadingZeroBits)) - 1
    for _ in 0 ..< 100:
      let w = mask and td.rand(typeof(result))
      if w < top:
        return w
    raiseAssert "Not here (!)"

# -----------------------

proc randomisedLeafs(
    db: AristoDbRef;
    td: var PrngDesc;
       ): seq[(LeafTie,VertexID)] =
  result = db.top.lTab.pairs.toSeq.filterIt(it[1].isvalid).sorted(
    cmp = proc(a,b: (LeafTie,VertexID)): int = cmp(a[0], b[0]))
  if 2 < result.len:
    for n in 0 ..< result.len-1:
      let r = n + td.rand(result.len - n)
      result[n].swap result[r]

proc innerCleanUp(db: AristoDbRef) =
  ## Defer action
  let rc = db.txTop()
  if rc.isOk:
    let rx = rc.value.collapse(commit=false)
    if rx.isErr:
      check rx.error == (0,0)
  db.finish(flush=true)

proc saveToBackend(
    tx: var AristoTxRef;
    chunkedMpt: bool;
    relax: bool;
    noisy: bool;
    debugID: int;
      ): bool =
  var db = tx.to(AristoDbRef)

  # Verify context: nesting level must be 1 (i.e. two transactions)
  block:
    block:
      let level = tx.level
      if level != 2:
        check level == 2
        return
    block:
      let rc = db.checkCache(relax=true)
      if rc.isErr:
        check rc.error == (0,0)
        return

  # Commit and hashify the current layer
  block:
    block:
      let rc = tx.commit()
      if rc.isErr:
        check rc.error == (0,0)
        return
    block:
      # Make sure MPT hashes are OK
      if db.top.dirty:
        check db.top.dirty == false
        return
    block:
      let rc = db.txTop()
      if rc.isErr:
        check rc.error == 0
        return
      tx = rc.value
      let level = tx.level
      if level != 1:
        check level == 1
        return
    block:
      let rc = db.checkBE(relax=true)
      if rc.isErr:
        check rc.error == (0,0)
        return

  # Commit and save to backend
  block:
    block:
      let rc = tx.commit()
      if rc.isErr:
        check rc.error == (0,0)
        return
    block:
      # Make sure MPT hashes are OK
      if db.top.dirty:
        check db.top.dirty == false
        return
    block:
      let rc = db.txTop()
      if rc.isOk:
        check rc.value.level < 0 # force error
        return
    block:
      let rc = db.stow(stageLimit=MaxFilterBulk, chunkedMpt=chunkedMpt)
      if rc.isErr:
        check rc.error == (0,0)
        return
    block:
      let rc = db.checkBE(relax=relax)
      if rc.isErr:
        check rc.error == (0,0)
        return

  # Update layers to original level
  tx = db.txBegin().value.to(AristoDbRef).txBegin().value

  true

proc saveToBackendWithOops(
    tx: var AristoTxRef;
    chunkedMpt: bool;
    noisy: bool;
    debugID: int;
    oops: (int,AristoError);
      ): bool =
  var db = tx.to(AristoDbRef)

  # Verify context: nesting level must be 1 (i.e. two transactions)
  block:
    block:
      let level = tx.level
      if level != 2:
        check level == 2
        return

  # Commit and hashify the current layer
  block:
    block:
      let rc = tx.commit()
      if rc.isErr:
        check rc.error == (0,0)
        return
    block:
      # Make sure MPT hashes are OK
      if db.top.dirty:
        check db.top.dirty == false
        return
    block:
      let rc = db.txTop()
      if rc.isErr:
        check rc.error == 0
        return
      tx = rc.value
      let level = tx.level
      if level != 1:
        check level == 1
        return

  # Commit and save to backend
  block:
    block:
      let rc = tx.commit()
      if rc.isErr:
        check rc.error == (0,0)
        return
    block:
      # Make sure MPT hashes are OK
      if db.top.dirty:
        check db.top.dirty == false
        return
    block:
      let rc = db.txTop()
      if rc.isOk:
        check rc.value.level < 0
        return
    block:
      let rc = db.stow(stageLimit=MaxFilterBulk, chunkedMpt=chunkedMpt)
      if rc.isErr:
        check rc.error == (0,0)
        return

  # Update layers to original level
  tx = db.txBegin().value.to(AristoDbRef).txBegin().value

  true


proc fwdWalkVerify(
    db: AristoDbRef;
    root: VertexID;
    leftOver: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): bool =
  let
    nLeafs = leftOver.len
  var
    leftOver = leftOver
    last = LeafTie()
    n = 0
  for (key,_) in db.right low(LeafTie,root):
    if key notin leftOver:
      noisy.say "*** fwdWalkVerify", " id=", n + (nLeafs + 1) * debugID
      check key in leftOver
      return
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = low(LeafTie,root)
  elif last != high(LeafTie,root):
    last = last + 1
  let rc = last.right db
  if rc.isOk or rc.error[1] != NearbyBeyondRange:
    check rc == WalkStopRc
    return

  if n != nLeafs:
    check n == nLeafs
    return

  true

proc revWalkVerify(
    db: AristoDbRef;
    root: VertexID;
    leftOver: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): bool =
  let
    nLeafs = leftOver.len
  var
    leftOver = leftOver
    last = LeafTie()
    n = 0
  for (key,_) in db.left high(LeafTie,root):
    if key notin leftOver:
      noisy.say "*** revWalkVerify", " id=", n + (nLeafs + 1) * debugID
      check key in leftOver
      return
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = high(LeafTie,root)
  elif last != low(LeafTie,root):
    last = last - 1
  let rc = last.left db
  if rc.isOk or rc.error[1] != NearbyBeyondRange:
    check rc == WalkStopRc
    return

  if n != nLeafs:
    check n == nLeafs
    return

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testTxMergeAndDelete*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var
    prng = PrngDesc.init 42
    db = AristoDbRef()
    fwdRevVfyToggle = true
  defer:
    db.finish(flush=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      let rc = newAristoDbRef(BackendRocksDB,rdbPath)
      if rc.isErr:
        check rc.error == 0
        return
      rc.value

    # Start transaction (double frame for testing)
    check db.txTop.isErr
    var tx = db.txBegin().value.to(AristoDbRef).txBegin().value
    check tx.isTop()
    check tx.level == 2

    # Reset database so that the next round has a clean setup
    defer: db.innerCleanUp

    # Merge leaf data into main trie (w/vertex ID 1)
    let kvpLeafs = w.kvpLst.mapRootVid VertexID(1)
    for leaf in kvpLeafs:
      let rc = db.merge leaf
      if rc.isErr:
        check rc.error == 0
        return

    # List of all leaf entries that should be on the database
    var leafsLeft = kvpLeafs.mapIt(it.leafTie).toHashSet

    # Provide a (reproducible) peudo-random copy of the leafs list
    let leafVidPairs = db.randomisedLeafs prng
    if leafVidPairs.len != leafsLeft.len:
      check leafVidPairs.len == leafsLeft.len
      return

    # Trigger subsequent saving tasks in loop below
    let (saveMod, saveRest, relax) = block:
      if leafVidPairs.len < 17:    (7, 3, false)
      elif leafVidPairs.len < 31: (11, 7, false)
      else:   (leafVidPairs.len div 5, 11, true)

    # === Loop over leafs ===
    for u,lvp in leafVidPairs:
      let
        runID = n + list.len * u
        tailWalkVerify = 7 # + 999
        doSaveBeOk = ((u mod saveMod) == saveRest)
        (leaf, lid) = lvp

      if doSaveBeOk:
        if not tx.saveToBackend(
            chunkedMpt=false, relax=relax, noisy=noisy, runID):
          return

      # Delete leaf
      let rc = db.delete leaf
      if rc.isErr:
        check rc.error == (0,0)
        return

      # Update list of remaininf leafs
      leafsLeft.excl leaf

      let deletedVtx = tx.db.getVtx lid
      if deletedVtx.isValid:
        check deletedVtx.isValid == false
        return

      # Walking the database is too slow for large tables. So the hope is that
      # potential errors will not go away and rather pop up later, as well.
      if leafsLeft.len <= tailWalkVerify:
        if u < leafVidPairs.len-1:
          if fwdRevVfyToggle:
            fwdRevVfyToggle = false
            if not db.fwdWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return
          else:
            fwdRevVfyToggle = true
            if not db.revWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return

    when true and false:
      noisy.say "***", "del(9) n=", n, "/", list.len, " nLeafs=", kvpLeafs.len

  true


proc testTxMergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                         # Rocks DB storage directory
    resetDb = false;
    idPfx = "";
    oops: KnownHasherFailure = @[];
      ): bool =
  let
    oopsTab = oops.toTable
  var
    db = AristoDbRef()
    tx = AristoTxRef(nil)
    rootKey: HashKey
    count = 0
  defer:
    db.finish(flush=true)

  for n,w in list:

    # Start new database upon request
    if resetDb or w.root != rootKey or w.proof.len == 0:
      db.innerCleanUp
      db = block:
        let rc = newAristoDbRef(BackendRocksDB,rdbPath)
        if rc.isErr:
          check rc.error == 0
          return
        rc.value

      # Start transaction (double frame for testing)
      tx = db.txBegin().value.to(AristoDbRef).txBegin().value
      check tx.isTop()

      # Update root
      rootKey = w.root
      count = 0
    count.inc

    let
      testId = idPfx & "#" & $w.id & "." & $n
      runID = n
      lstLen = list.len
      sTabLen = db.top.sTab.len
      lTabLen = db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie

    var
      proved: tuple[merged: int, dups: int, error: AristoError]
    if 0 < w.proof.len:
      let rc = db.merge(rootKey, VertexID(1))
      if rc.isErr:
        check rc.error == 0
        return

      proved = db.merge(w.proof, rc.value) # , noisy)

      check proved.error in {AristoError(0),MergeHashKeyCachedAlready}
      check w.proof.len == proved.merged + proved.dups
      check db.top.lTab.len == lTabLen
      check db.top.sTab.len <= proved.merged + sTabLen
      check proved.merged < db.top.pAmk.len

    let
      merged = db.merge leafs

    check db.top.lTab.len == lTabLen + merged.merged
    check merged.merged + merged.dups == leafs.len

    block:
      if merged.error notin {AristoError(0), MergeLeafPathCachedAlready}:
        check merged.error in {AristoError(0), MergeLeafPathCachedAlready}
        return

    block:
      let oops = oopsTab.getOrDefault(testId,(0,AristoError(0)))
      if not tx.saveToBackendWithOops(
          chunkedMpt=true, noisy=noisy, debugID=runID, oops):
        return

    when true and false:
      noisy.say "***", "proofs(6) <", n, "/", lstLen-1, ">",
        " groups=", count, " proved=", proved.pp, " merged=", merged.pp
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
