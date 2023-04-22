import FIFO::*;
import Vector::*;
import BRAM::*;
import BRAMFIFO::*;

import Processor::*;
import Defines::*;
import Scoreboard::*;

typedef struct {
	Bit#(64) addr;
	Bit#(32) bytes;
} MemPortReq deriving (Eq,Bits);


typedef 512 DramWordBits;
typedef TDiv#(DramWordBits, 32) CacheLineWords;
typedef TLog#(CacheLineWords) CacheLineWordsSz;

typedef 32 AddrSz;

function Bit#(32) reverseEndian(Bit#(32) word);
	Bit#(32) nw = {word[7:0], word[15:8], word[23:16], word[31:24]};
	return nw;
endfunction

interface CacheIfc#(numeric type cacheRowCntSz );
	method Action cacheReq(MemReq32 req);
	method ActionValue#(Word) cacheResp;

	method ActionValue#(MemPortReq) memReadReq;
	method ActionValue#(MemPortReq) memWriteReq;
	method ActionValue#(Bit#(DramWordBits)) memWriteWord;
	method Action memReadWord(Bit#(DramWordBits) word);
endinterface


module mkCacheDirect#(Bool verbose) (CacheIfc#(cacheRowCntSz))
	provisos (Add#(1,a__,cacheRowCntSz)
		, Add#(cacheRowCntSz, b__, AddrSz)
		, Add#(CacheLineWordsSz, 2, cacheLineBytesSz)
		, Add#(cacheLineBytesSz, cacheRowCntSz, cacheAddressSz)
		, Add#(tagSz,cacheAddressSz,AddrSz)
	);

	Integer iCacheLineBytesSz = valueOf(cacheLineBytesSz);

	ScoreboardIfc#(16) sb <- mkScoreboard;
	// tag, words, valid, dirty
	BRAM2Port#(Bit#(cacheRowCntSz), Tuple4#(Bit#(tagSz), Vector#(TExp#(CacheLineWordsSz), Word),Bool,Bool)) mem <- mkBRAM2Server(defaultValue); 

	Reg#(Bit#(TAdd#(1,cacheRowCntSz))) cacheInitCounter <- mkReg(1<<valueOf(cacheRowCntSz)); 
	rule initCache(cacheInitCounter > 0 );
		mem.portB.request.put( BRAMRequest{write:True, responseOnWrite:False, address:truncate(cacheInitCounter), datain:tuple4(?,?, False,False)});
		cacheInitCounter <= cacheInitCounter - 1;
	endrule


	// Write?, cache?(/mem), addr, word
	FIFO#(Tuple5#(Bool,Bool,Word,Word,Bit#(2))) cacheOpOrderQ <- mkSizedBRAMFIFO(64);
	FIFO#(MemPortReq) memReadReqQ <- mkFIFO;
	FIFO#(MemPortReq) memWriteReqQ <- mkFIFO;
	FIFO#(Bit#(512)) memWriteQ <- mkFIFO;
	FIFO#(Bit#(512)) memReadQ <- mkFIFO;

	FIFO#(MemReq32) cacheReferenceBypassQ <- mkFIFO;
	FIFO#(Word) cacheReadRespQ <- mkFIFO;
	rule procCacheReference;
		let w <- mem.portA.response.get;
		let r = cacheReferenceBypassQ.first;
		cacheReferenceBypassQ.deq;

		Bit#(tagSz) readTag = tpl_1(w);
		Bit#(tagSz) reqTag = truncate(r.addr>>valueOf(cacheAddressSz));

		if ( verbose ) $write( "tags: %x %x\n", readTag, reqTag );

		if (tpl_3(w) && readTag == reqTag) begin // cache hit
			cacheOpOrderQ.enq(tuple5(r.write, True, r.addr, r.word, r.bytes));
			Bit#(CacheLineWordsSz) wid = truncate(r.addr>>2);
			if ( r.write == False ) begin
				Bit#(8) shoff = zeroExtend(r.addr[1:0]);
				cacheReadRespQ.enq(tpl_2(w)[wid]>>(shoff*8));
			end else begin
				Vector#(TExp#(CacheLineWordsSz), Word) newline = tpl_2(w);
				Word wbword = newline[wid];
				if ( r.bytes == 3 ) wbword = r.word; // word
				else if (r.bytes == 1) begin // half
					Bit#(8) shoff = zeroExtend(r.addr[1:0]);
					Bit#(16) mask = -1;
					Bit#(32) wmask = zeroExtend(mask)<<(shoff*8);
					Bit#(32) wval = ((r.word&zeroExtend(mask))<<(shoff*8));
					Bit#(32) rmask = ~(wmask);
					wbword = (wbword & rmask) | wval;
					//( r.bytes == 1 ) wbword = 
				end else begin // byte
					Bit#(8) shoff = zeroExtend(r.addr[1:0]);
					Bit#(8) mask = -1;
					Bit#(32) wmask = zeroExtend(mask)<<(shoff*8);
					$write("~~~~ %x %x\n", mask, wmask);
					Bit#(32) wval = ((r.word&zeroExtend(mask))<<(shoff*8));
					Bit#(32) rmask = ~(wmask);
					wbword = (wbword & rmask) | wval;
				end

				newline[wid] = wbword;
				mem.portB.request.put( BRAMRequest{write:True, responseOnWrite:False, address:truncate(r.addr>>valueOf(cacheLineBytesSz)), datain:tuple4(reqTag,newline, True,True)});
			end
		end else begin // cache miss
			cacheOpOrderQ.enq(tuple5(r.write, False,r.addr, r.word, r.bytes));
			//writeback, and then read new
			Bit#(cacheRowCntSz) rowaddr = truncate(r.addr>>iCacheLineBytesSz);

			if ( tpl_3(w) && tpl_4(w) ) begin
				Bit#(32) caddr = {readTag,rowaddr,0};
				memWriteReqQ.enq(MemPortReq{addr:zeroExtend(caddr), bytes: 64});
				memWriteQ.enq(pack(tpl_2(w)));
				if ( verbose ) $write( "Writeback to %x\n", caddr);
			end

			Bit#(32) caddrnew = {reqTag,rowaddr,0};
			memReadReqQ.enq(MemPortReq{addr:zeroExtend(caddrnew), bytes: 64});
			if ( verbose ) $write( "Reading memory from %x\n", caddrnew);
		end
	endrule

	FIFO#(Word) cacheRespQ <- mkFIFO;
	rule procDeqSb;
		let o = cacheOpOrderQ.first;
		cacheOpOrderQ.deq;
		sb.deq;
		if ( !tpl_2(o) ) begin // comes from DRAM
			memReadQ.deq;
			let d = memReadQ.first;
			Vector#(TExp#(CacheLineWordsSz), Word) newline = unpack(d);
		
			let raddr = tpl_3(o);
			let rword = tpl_4(o);
			let rbytes = tpl_5(o);
			Bit#(CacheLineWordsSz) wid = truncate(raddr>>2);
			Bit#(tagSz) reqTag = truncate(raddr>>valueOf(cacheAddressSz));
			if ( verbose ) $write( "reqTag: %x\n", reqTag );

			if ( tpl_1(o) ) begin // write to cache
				Word wbword = newline[wid];
				if ( rbytes == 3 ) wbword = rword; // word
				else if (rbytes == 1) begin // half
					Bit#(8) shoff = zeroExtend(raddr[1:0]);
					Bit#(16) mask = -1;
					Bit#(32) wmask = zeroExtend(mask)<<(shoff*8);
					Bit#(32) wval = ((rword&zeroExtend(mask))<<(shoff*8));
					Bit#(32) rmask = ~(wmask);
					wbword = (wbword & rmask) | wval;
					//( r.bytes == 1 ) wbword = 
				end else begin // byte
					Bit#(8) shoff = zeroExtend(raddr[1:0]);
					Bit#(8) mask = -1;
					Bit#(32) wmask = zeroExtend(mask)<<(shoff*8);
					Bit#(32) wval = ((rword&zeroExtend(mask))<<(shoff*8));
					Bit#(32) rmask = ~(wmask);
					wbword = (wbword & rmask) | wval;
				end

				newline[wid] = wbword;
				mem.portB.request.put( BRAMRequest{write:True, responseOnWrite:False, address:truncate(raddr>>valueOf(cacheLineBytesSz)), datain:tuple4(reqTag,newline,True,False)});
			end else begin // read from cache
				//if ( verbose ) $write( "DRAM read word %x\n" , newline[wid]);
				mem.portB.request.put( BRAMRequest{write:True, responseOnWrite:False, address:truncate(raddr>>valueOf(cacheLineBytesSz)), datain:tuple4(reqTag,newline, True,True)});
				Bit#(8) shoff = zeroExtend(raddr[1:0]);
				cacheRespQ.enq(newline[wid]>>(shoff*8));
			end
		end else begin
			if ( !tpl_1(o) ) begin // read from cache
				cacheReadRespQ.deq;
				cacheRespQ.enq(cacheReadRespQ.first);
			end
		end
	endrule

	FIFO#(MemReq32) cacheReqQ <- mkFIFO;
	rule stallCacheReq;
		let req = cacheReqQ.first;

		// use hash to be efficient, no false negatives
		Bit#(5) addrhash = truncate(req.addr>>iCacheLineBytesSz); //FIXME hash better
		Bit#(cacheRowCntSz) cacheoff = truncate(req.addr>>iCacheLineBytesSz);
		if ( verbose ) $write( "Cache req off: %x\n", cacheoff );

		Bool stallWrite = sb.search1(addrhash);
		if ( !(stallWrite) ) begin
			cacheReqQ.deq;

			mem.portA.request.put( BRAMRequest{write:False, responseOnWrite:False, address:cacheoff, datain:?});
			cacheReferenceBypassQ.enq(req);
			sb.enq(addrhash);
		end else begin
		end
	endrule
	
	method Action cacheReq(MemReq32 req) if ( cacheInitCounter == 0 );
		cacheReqQ.enq(req);
		//$write("Cache req to %x (%d)\n", req.addr, req.bytes );
	endmethod
	method ActionValue#(Word) cacheResp;
		cacheRespQ.deq;
		return cacheRespQ.first;
	endmethod

	method ActionValue#(MemPortReq) memReadReq;
		memReadReqQ.deq;
		return memReadReqQ.first;
	endmethod
	method ActionValue#(MemPortReq) memWriteReq;
		memWriteReqQ.deq;
		return memWriteReqQ.first;
	endmethod
	method ActionValue#(Bit#(DramWordBits)) memWriteWord;
		memWriteQ.deq;
		return memWriteQ.first;
	endmethod
	method Action memReadWord(Bit#(DramWordBits) word);
		if ( verbose ) $write( "Read resp: %x\n", word );
		memReadQ.enq(word);
	endmethod
endmodule
