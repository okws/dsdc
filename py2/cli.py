
import RPC
import RPCProto
import dsdc_prot

c = RPC.SClient (dsdc_prot, dsdc_prot.DSDC_PROG, dsdc_prot.DSDC_VERS, 
		 "127.0.0.1", 30002)
