type
  PeerExchangePeerInfo* = object
    enr*: seq[byte] # RLP encoded ENR: https://eips.ethereum.org/EIPS/eip-778

  PeerExchangeRequest* = object
    numPeers*: uint64

  PeerExchangeResponse* = object
    peerInfos*: seq[PeerExchangePeerInfo]

# TODO: is this even needed?
  PeerExchangeRpc* = object
    request*: PeerExchangeRequest
    response*: PeerExchangeResponse
