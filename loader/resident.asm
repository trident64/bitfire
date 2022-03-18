;
; (c) Copyright 2021 by Tobias Bindhammer. All rights reserved.
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions are met:
;     * Redistributions of source code must retain the above copyright
;       notice, this list of conditions and the following disclaimer.
;     * Redistributions in binary form must reproduce the above copyright
;       notice, this list of conditions and the following disclaimer in the
;       documentation and/or other materials provided with the distribution.
;     * The name of its author may not be used to endorse or promote products
;       derived from this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
; ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
; DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
; (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
; ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;

!convtab pet
!cpu 6510
!src "music.inc"
!src "config.inc"
!src "constants.inc"

LZ_BITS_LEFT		= 0
OPT_FULL_SET		= 0

!if CONFIG_DECOMP = 0 {
bitfire_load_addr_lo	= CONFIG_ZP_ADDR + 0		;in case of no loadcompd, store the hi- and lobyte of loadaddress separatedly
bitfire_load_addr_hi	= CONFIG_ZP_ADDR + 1
preamble		= CONFIG_ZP_ADDR + 2		;5 bytes
	} else {
lz_bits			= CONFIG_ZP_ADDR + 0		;1 byte
lz_dst			= CONFIG_ZP_ADDR + 1		;2 byte
lz_src			= CONFIG_ZP_ADDR + 3		;2 byte
lz_len_hi		= CONFIG_ZP_ADDR + 5		;1 byte
preamble		= CONFIG_ZP_ADDR + 6		;5 bytes
bitfire_load_addr_lo	= lz_src + 0
bitfire_load_addr_hi	= lz_src + 1
}

block_length		= preamble + 0
block_addr_lo		= preamble + 1
block_addr_hi		= preamble + 2
block_barrier		= preamble + 3
block_status		= preamble + 4
filenum			= block_barrier


!if CONFIG_DECOMP = 1 {
!macro get_lz_bit {
        !if LZ_BITS_LEFT = 1 {
			asl <lz_bits
        } else {
			lsr <lz_bits
        }
}

!macro set_lz_bit_marker {
        !if LZ_BITS_LEFT = 1 {
        	        rol
        } else {
	                ror
        }
}
}

!macro inc_src_ptr {
	!if CONFIG_LOADER = 1 {
			jsr lz_next_page		;sets X = 0, so all sane
	} else {
			inc <lz_src + 1
	}
}

bitfire_install_	= CONFIG_INSTALLER_ADDR	;define that label here, as we only aggregate labels from this file into loader_*.inc

			* = CONFIG_RESIDENT_ADDR
.lz_gap1
!if CONFIG_AUTODETECT = 1 {
link_chip_types
link_sid_type		;%00000001		;bit set = new, bit cleared = old
link_cia1_type		;%00000010
link_cia2_type		;%00000100
			!byte $00
}
!if CONFIG_NMI_GAPS = 1 {
	!if CONFIG_AUTODETECT = 0 {
			nop
	}
			nop
			nop
			nop
			nop
			nop
			nop
			nop
			nop
			nop
}

			;those calls could be a macro, but they are handy to be jumped to so loading happens while having all mem free, and code is entered afterwards
;	!if CONFIG_DECOMP = 1 {
;;			;expect $01 to be $35
;		!if CONFIG_LOADER = 1 {
;
;			;XXX TODO not used much, throw out
;link_load_next_double
;			;loads a splitted file, first part up to $d000 second part under IO
;			jsr link_load_next_comp
;link_load_next_raw_decomp
;			jsr link_load_next_raw
;		}
;link_decomp_under_io
;			dec $01				;bank out IO
;			jsr link_decomp			;depack
;			inc $01				;bank in again
;			rts
;	}

;---------------------------------------------------------------------------------
;LOADER STUFF
;---------------------------------------------------------------------------------

!if CONFIG_LOADER = 1 {
			;XXX we do not wait for the floppy to be idle, as we waste enough time with depacking or the fallthrough on load_raw to have an idle floppy
bitfire_send_byte_
			sec
			ror
			sta <filenum
			lda #$3f
.ld_loop
			eor #$20
			jsr .ld_set_dd02		;waste lots of cycles upon write, so bits do not arrive too fast @floppy
			lsr <filenum
			bne .ld_loop
			;clc				;force final value to be $3f again (bcc will hit in later on)
.ld_set_dd02						;moved loop code to here, so that enough cycles pass by until $dd02 is set back to $3f after whole byte is transferred, also saves a byte \o/
			tax				;x = $1f/$3f / finally x is always $3f after 8 rounds (8 times eor #$20)
			bcs +
			sbx #$10			;x = $0f/$2f
+
			stx $dd02			;restore $dd02
			rts				;filenum and thus barrier is $00 now, so whenever we enter load_next for a first time, it will load until first block is there

	!if CONFIG_FRAMEWORK = 1 {
link_load_next_raw
			lda #BITFIRE_LOAD_NEXT
link_load_raw
	}
bitfire_loadraw_
			jsr bitfire_send_byte_		;easy, open...
-
.ld_load_raw
			jsr .ld_pblock			;fetch all blocks until eof
			bcc -
			;rts				;just run into ld_pblock code again that will then jump to .ld_pend and rts
.ld_pblock
			lda $dd00			;bit 6 is always set if not ready or idle/EOF
			anc #$c0			;focus on bit 7 and 6 and copy bit 7 to carry (set if floppy is idle/eof is reached)
			bne .ld_en_exit + 1		;block ready? if so, a = 0 (block ready + busy) if not -> rts
.ld_pblock_
			ldy #$05			;5 bytes
			;lda #$00
			ldx #<preamble
			jsr .ld_set_block_tgt		;load 5 bytes preamble - returns with C = 0 at times

			ldy <block_length		;load blocklength
			ldx <block_addr_lo		;block_address lo
			lda <block_addr_hi		;block_address hi
			bit <block_status		;status -> first_block?
			bmi .ld_set_block_tgt
			stx bitfire_load_addr_lo	;yes, store load_address (also lz_src in case depacker is present)
			sta bitfire_load_addr_hi
.ld_set_block_tgt
			stx .ld_store + 1		;setup target for block data
			sta .ld_store + 2
							;XXX TODO, change busy signal 1 = ready, 0 = eof, leave ld_pblock with carry set, also tay can be done after preamble load as last value is still in a
			sec				;loadraw enters ld_pblock with C = 0
							;lax would be a7, would need to swap carry in that case: eof == clc, block read = sec
			ldx #$8e			;opcode for stx	-> repair any rts being set (also accidently) by y-index-check
			top
.ld_en_exit
			ldx #$60
			stx .ld_gend			;XXX TODO would be nice if we could do that with ld_store in same time, but happens at different timeslots :-(
			bpl +				;do bpl first
bitfire_ntsc5
			bmi .ld_gentry			;also bmi is now in right place to be included in ntsc case to slow down by another 2 cycles. bpl .ld_gloop will then point here and bmi will just fall through always
.ld_gloop
			ldx #$3f
bitfire_ntsc0		ora $dd00 - $3f,x
			stx $dd02
			lsr				;%xxxxx111
			lsr				;%xxxxxx11 1
			dey
			beq .ld_en_exit
+
			ldx #$37
bitfire_ntsc1		ora $dd00
			stx $dd02
			ror				;c = 1
			ror				;c = 1 a = %11xxxxxx
			ldx #$3f
			sax .ld_nibble + 1
bitfire_ntsc2		and $dd00
			stx $dd02

.ld_nibble		ora #$00
.ld_store		sta $b00b,y
.ld_gentry
			lax <CONFIG_LAX_ADDR
bitfire_ntsc3		adc $dd00
							;%xx1110xx
.ld_gend
			stx $dd02			;carry is cleared now after last adc, we can exit here with carry cleared (else set if EOF) and do our rts with .ld_gend
			lsr				;%xxx1110x
			lsr				;%xxxx1110
bitfire_ntsc4		bpl .ld_gloop			;BRA, a is anything between 0e and 3e

!if >* != >.ld_gloop { !error "getloop code crosses page!" }
;XXX TODO in fact the branch can also take 4 cycles if needed, ora $dd00 - $3f,x wastes one cycle anyway

}

;---------------------------------------------------------------------------------
;DEPACKER STUFF
;---------------------------------------------------------------------------------

!if CONFIG_DECOMP = 1 {
			;------------------
			;ELIAS FETCH
			;------------------
.lz_refill_bits
			tax				;save bits fetched so far
			lda (lz_src),y			;fetch another lz_bits byte from stream
			+set_lz_bit_marker
			sta <lz_bits
			inc <lz_src + 0 		;postponed pointer increment, so no need to save A on next_page call
			beq .lz_inc_src_refill
.lz_inc_src_refill_
			txa				;restore fetched bits, also postponed, so A can be trashed on lz_inc_src above
			bcs .lz_lend			;last bit fetched?
.lz_get_loop
			+get_lz_bit			;fetch payload bit
.lz_length_16_
			rol				;shift in new payload bit
			bcs .lz_length_16		;first 1 drops out from lowbyte, need to extend to 16 bit, unfortunatedly this does not work with inverted numbers
.lz_length
			+get_lz_bit			;fetch control bit
			bcc .lz_get_loop		;need more bits
			beq .lz_refill_bits		;buffer is empty, fetch new bits
.lz_lend						;was the last bit
			rts
.lz_length_16						;this routine happens very rarely, so we can waste cycles
			pha				;save so far received lobyte
			tya				;was lda #$01, but A = 0 + upcoming rol makes this also start with A = 1
			jsr .lz_length_16_		;get up to 7 more bits
			sta <lz_len_hi			;and save hibyte
			;top				;skip upcoming ldx #$80
			ldx #$b0
		!if OPT_FULL_SET = 1 {
			lda #.lz_cp_page - .lz_set1 - 2
			ldy #.lz_cp_page - .lz_set1 - 2
			bne +
.lz_lenchk_dis
.lz_eof
			pha
			ldx #$a9
			lda #$01
			tay
+
			stx .lz_set1
			stx .lz_set2
			sta .lz_set1 + 1
			sty .lz_set2 + 1
			ldy #$00
			pla
		} else {
			pla
			top
.lz_lenchk_dis
.lz_eof
			ldx #$80
			stx .lz_set1
			stx .lz_set2
                }
			rts

			;------------------
			;DECOMP INIT
			;------------------
bitfire_decomp_
link_decomp
	!if CONFIG_LOADER = 1 {
			lda #(.lz_start_over - .lz_skip_poll) - 2	;9e
			ldx #$60
			bne .loadcomp_entry
		!if CONFIG_FRAMEWORK = 1 {
link_load_next_comp
			lda #BITFIRE_LOAD_NEXT
link_load_comp
		}
bitfire_loadcomp_
			jsr bitfire_send_byte_		;returns now with x = $3f
			lda #(.lz_poll - .lz_skip_poll) - 2		;96
			ldx #$08
.loadcomp_entry
			sta .lz_skip_poll + 1
			stx .lz_skip_fetch

			jsr .lz_next_page_		;shuffle in data first until first block is present, returns with Y = 0, but on loadcomp only, so take care!
	}
							;copy over end_pos and lz_dst from stream XXX would also work from x = 0 .. 2 -> lax #0 tay txa inx cpx #2 -> a = 1 + sec at end
			ldy #$00			;needs to be set in any case, also plain decomp enters here
			sty .lz_offset_lo + 1		;initialize offset with $0000
			sty .lz_offset_hi + 1
			ldx #$ff
-
			lda (lz_src),y
			sta <lz_dst + 1, x
			inc <lz_src + 0
			bne +
			+inc_src_ptr
+
			inx				;dex + sec set
			beq -
			txa				;save x prior to decrement, so that A = 1 after loop ends, in case fetch another byte? First byte should be lz_bits?
			sec
			bne .lz_start_depack		;start with a literal, X = 0, still annoying, but now need to reverse bitorder for lz_bits this way

			;------------------
			;SELDOM STUFF
			;------------------
.lz_inc_src_refill
			+inc_src_ptr
			bne .lz_inc_src_refill_
.lz_inc_src_match
			+inc_src_ptr
			bne .lz_inc_src_match_
.lz_inc_src_lit
			+inc_src_ptr
			bcs .lz_inc_src_lit_

!if CONFIG_NMI_GAPS = 1 {
			!ifdef .lz_gap2 {
				!warn .lz_gap2 - *, " bytes left until gap2"
			}
!align 255,0
.lz_gap2
			nop
			nop
			nop
			nop
			nop
			nop
			nop
			nop
			nop

!if .lz_gap2 - .lz_gap1 > $0100 {
		!error "code on first page too big, second gap does not fit!"
}
}
			;------------------
			;MATCH
			;------------------
-
			+get_lz_bit			;fetch payload bit
			rol				;add bit to number
.lz_match
			+get_lz_bit			;fetch control bit
			bcc -				;not yet done, fetch more bits

			bne +				;last bit or bitbuffer empty? fetched 1 to 4 bits now
			jsr .lz_refill_bits		;refill bitbuffer
			beq .lz_eof			;so offset was $100 as lowbyte is $00, only here 4-8 bits are fetched, this is our eof marker -> disable len-check and rts
+
			sbc #$01			;subtract 1, elias numbers range from 1..256, we need 0..255
			lsr				;set bit 15 to 0 while shifting hibyte
			sta .lz_offset_hi + 1		;hibyte of offset

			lda (lz_src),y			;fetch another byte directly, same as refill_bits...
			ror				;and shift -> first bit for lenth is in carry, and we have %0xxxxxxx xxxxxxxx as offset
			sta .lz_offset_lo + 1		;lobyte of offset

			inc <lz_src + 0			;postponed, so no need to save A on next_page call
			beq .lz_inc_src_match
.lz_inc_src_match_
			lda #$01			;fetch new number, start with 1
			;ldy #$fe			;XXX preferring that path gives ~0,1% speed gain
			;bcs .lz_match_len2
			bcs .lz_match_big		;length = 1, do it the very short way
-
			+get_lz_bit			;fetch more bits
			rol
			+get_lz_bit
			bcc -
			bne .lz_match_big
			;ldy #$00
			jsr .lz_refill_bits		;fetch remaining bits
			bcs .lz_match_big		;lobyte != 0? If zero, fall through

			;------------------
			;SELDOM STUFF
			;------------------
.lz_dst_inc
			inc <lz_dst + 1
			bcs .lz_dst_inc_
.lz_clc
			clc
			bcc .lz_clc_back
.lz_cp_page						;if we enter from a literal, we take care that x = 0 (given after loop run, after length fetch, we force it to zero by tax here), so that we can distinguish the code path later on. If we enter from a match x = $b0 (elias fetch) or >lz_dst_hi + 1, so never zero.
			txa
.lz_cp_page_						;a is already 0 if entered here
			dec <lz_len_hi
			bne +
			jsr .lz_lenchk_dis
+
			tax				;check a/x
			beq .lz_l_page			;do another page
			tya				;if entered from a match, x is anything between $01 and $ff due to inx stx >lz_dst + 1, except if we would depack to zp on a wrap around?
			beq .lz_m_page			;as Y = 0 and A = 0 now, we can skip the part that does Y = A xor $ff

			;------------------
			;POLLING
			;------------------
.lz_poll
	!if CONFIG_LOADER = 1 {
			bit $dd00
			bvs .lz_start_over
			jsr .ld_pblock			;yes, fetch another block, call is disabled for plain decomp
		!if OPT_FULL_SET = 1 {
			lda #$01			;restore initial length val
                }
	}
			;------------------
			;ENTRY POINT DEPACKER
			;------------------
.lz_start_over
		!if OPT_FULL_SET = 0 {
			lda #$01			;we fall through this check on entry and start with literal
                }
			+get_lz_bit
			bcs .lz_match			;after each match check for another match or literal?

			;------------------
			;LITERAL
			;------------------
.lz_literal
			+get_lz_bit
			bcs +
-
			+get_lz_bit			;fetch payload bit
			rol				;can also moved to front and executed once on start
			+get_lz_bit			;fetch payload bit
			bcc -
+
			bne +
.lz_start_depack
			jsr .lz_refill_bits
			beq .lz_cp_page_		;handle special case of length being $xx00
+
			tax
.lz_l_page
.lz_cp_lit						;XXX TODO copy with Y += 1 but have lz_src + 0 eor #$ff in x and countdown x, so that lz_src + 1 can be incremented in time?
			lda (lz_src),y			;/!\ Need to copy this way, or we run into danger to copy from an area that is yet blocked by barrier, this totally sucks, loading in order reveals that
			sta (lz_dst),y

			inc <lz_src + 0
			beq .lz_inc_src_lit
.lz_inc_src_lit_
			inc <lz_dst + 0
			beq .lz_dst_inc
.lz_dst_inc_
			dex
			bne .lz_cp_lit

		!if OPT_FULL_SET = 0 {
.lz_set1		bcc .lz_cp_page			;next page to copy, either enabled or disabled (bcc/nop #imm/bcs)
                } else {
.lz_set1		lda #$01			;next page to copy, either enabled or disabled (bcc/nop #imm/bcs)
                }
			;------------------
			;NEW OR OLD OFFSET
			;------------------
							;XXX TODO fetch length first and then decide if literal, match, repeat? But brings our checks for last bit to the end? need to check then on typebit? therefore entry for fetch is straight?
							;in case of type bit == 0 we can always receive length (not length - 1), can this used for an optimization? can we fetch length beforehand? and then fetch offset? would make length fetch simpler? place some other bit with offset?
		!if OPT_FULL_SET = 0 {
			lda #$01			;was A = 0, C = 1 -> A = 1 with rol, but not if we copy literal this way
                }
			+get_lz_bit
			bcs .lz_match			;either match with new offset or old offset

			;------------------
			;REPEAT LAST OFFSET
			;------------------
.lz_repeat
			+get_lz_bit
			bcs +
-
			+get_lz_bit			;fetch payload bit
			rol				;can also moved to front and executed once on start
			+get_lz_bit			;cheaper with 2 branches, as initial branch to .lz_literal therefore is removed
			bcc -
+
			bne +
			jsr .lz_refill_bits		;fetch more bits
			beq .lz_cp_page			;handle special case of length being $xx00
+
			sbc #$01			;subtract 1, will be added again on adc as C = 1
.lz_match_big						;we enter with length - 1 here from normal match
			eor #$ff
			tay
.lz_m_page
			eor #$ff			;restore A
.lz_match_len2
			adc <lz_dst + 0			;add length
			sta <lz_dst + 0
			bcs .lz_clc			;/!\ branch happens very seldom, if so, clear carry, XXX TODO if we would branch to * + 3 and we use $18 as lz_dst, we have our clc there :-( but we want zp usage to be configureable
			dec <lz_dst + 1			;subtract one more in this case
.lz_clc_back
.lz_offset_lo		sbc #$00			;carry is cleared, subtract (offset + 1)
			sta .lz_msrcr + 0
			lax <lz_dst + 1
.lz_offset_hi		sbc #$00
			sta .lz_msrcr + 1
.lz_cp_match						;XXX TODO if repeated offset: add literal size to .lz_msrcr and done?
.lz_msrcr = * + 1
			lda $beef,y
			sta (lz_dst),y
			iny
			bne .lz_cp_match
			inx
			stx <lz_dst + 1			;cheaper to get lz_dst + 1 into x than lz_dst + 0 for upcoming compare

		!if OPT_FULL_SET = 0 {
.lz_set2		bcc .lz_cp_page			;next page to copy, either enabled or disabled (bcc/nop #imm/bcs)
                } else {
.lz_set2		lda #$01			;next page to copy, either enabled or disabled (bcc/nop #imm/bcs)
                }
.lz_check_poll
			cpx <lz_src + 1			;check for end condition when depacking inplace, lz_dst + 0 still in X
.lz_skip_poll		bne .lz_start_over		;-> can be changed to .lz_poll, depending on decomp/loadcomp

			ldx <lz_dst + 0
			cpx <lz_src + 0
			bne .lz_start_over

							;XXX TODO, save one byte above and the beq lz_next_page can be omitted and lz_next_page copied here again
			;jmp .ld_load_raw		;but should be able to skip fetch, so does not work this way
			;top				;if lz_src + 1 gets incremented, the barrier check hits in even later, so at least one block is loaded, if it was $ff, we at least load the last block @ $ffxx, it must be the last block being loaded anyway
							;as last block is forced, we would always wait for last block to be loaded if we enter this loop, no matter how :-)
	!if CONFIG_LOADER = 1 {
			;------------------
			;NEXT PAGE IN STREAM
			;------------------
lz_next_page
			inc <lz_src + 1
.lz_next_page_						;preserves carry and X, clears Y, all sane
.lz_skip_fetch
			php				;save carry
			txa				;and x
			pha
.lz_fetch_sector					;entry of loop
			jsr .ld_pblock			;fetch another block
			bcs .lz_fetch_eof		;eof? yes, finish, only needed if files reach up to $ffxx -> barrier will be 0 then and upcoming check will always hit in -> this would suck
							;XXX TODO send a high enough barrier on last block being sent
			lda <lz_src + 1			;get current depack position
			cmp <block_barrier		;next pending block/barrier reached? If barrier == 0 this test will always loop on first call or until first-block with load-address arrives, no matter what .bitfire_lz_sector_ptr has as value \o/
							;on first successful .ld_pblock they will be set with valid values and things will be checked against correct barrier
			bcs .lz_fetch_sector		;already reached, loop
.lz_fetch_eof						;not reached, go on depacking
			;Y = 0				;XXX TODO could be used to return somewhat dirty from a jsr situation, this would pull two bytes from stack and return
			pla
			tax
			plp
			rts
	} else {
			rts
	}
}

;---------------------------------------------------------------------------------
;FRAMEWORK STUFF
;---------------------------------------------------------------------------------

!if CONFIG_FRAMEWORK = 1 {
	!if CONFIG_FRAMEWORK_BASEIRQ = 1 {
link_player
			pha
			tya
			pha
			txa
			pha
			inc $01				;should be save with $01 == $34/$35, except when music is @ >= $e000
	!if CONFIG_FRAMEWORK_MUSIC_NMI = 1 {
			lda $dd0d
	} else {
			dec $d019
	}
			jsr link_music_play
			dec $01

			pla
			tax
			pla
			tay
			pla
			rti
	}

			;this is the music play hook for all parts that they should call instead of for e.g. jsr $1003, it has a variable music location to be called
			;and advances the frame counter if needed

link_music_play
	!if CONFIG_FRAMEWORK_FRAMECOUNTER = 1 {
			inc link_frame_count + 0
			bne +
			inc link_frame_count + 1
+
	}
link_music_addr = * + 1
			jmp link_music_play_side1

	!if CONFIG_FRAMEWORK_FRAMECOUNTER = 1 {
link_frame_count
			!word 0
	}
}


bitfire_resident_size = * - CONFIG_RESIDENT_ADDR

;XXX TODO
;decide upon 2 bits with bit <lz_bits? bmi + bvs + bvc? bpl/bmi decides if repeat or not, bvs = length 2/check for new bits and redecide, other lengths do not need to check, this can alos be used on other occasions?
;do a jmp ($00xx) to determine branch?
