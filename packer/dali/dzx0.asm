!cpu 6510

CONFIG_ZP_ADDR		= $f0
LZ_BITS_LEFT            = 0

lz_bits			= CONFIG_ZP_ADDR + 0
lz_dst			= CONFIG_ZP_ADDR + 1
lz_src			= CONFIG_ZP_ADDR + 3
lz_len_hi		= CONFIG_ZP_ADDR + 5

!macro get_lz_bit {
        !if LZ_BITS_LEFT = 1 {
                asl <lz_bits
        } else {
                lsr <lz_bits
        }
}

!macro set_lz_bit_marker {
        !if LZ_BITS_LEFT = 1{
                rol
        } else {
                ror
        }
}

!macro init_lz_bits {
        !if LZ_BITS_LEFT = 1 {
                        lda #$40
                        sta <lz_bits                    ;start with an empty lz_bits, first +get_lz_bit leads to literal this way and bits are refilled upon next shift
        } else {
                        stx <lz_bits
        }
}

;---------------------------------------------------------------------------------
;DEPACKER STUFF
;---------------------------------------------------------------------------------

			sta <lz_src + 1
			stx <lz_src + 0

                        ldy #$00                        ;needs to be set in any case, also plain decomp enters here
                        ldx #$02
			+init_lz_bits
-
                        lda (lz_src),y
                        sta <lz_dst + 0 - 1, x
                        inc <lz_src + 0
                        bne +
                        inc <lz_src + 1
+
                        dex
                        bne -
                        stx .lz_offset_lo + 1           ;initialize offset with $0000
                        stx .lz_offset_hi + 1
                        stx <lz_len_hi

			;------------------
			;LITERAL
			;------------------
.lz_start_over
			lda #$01			;we fall through this check on entry and start with literal
			+get_lz_bit
			bcs .lz_match			;after each match check for another match or literal?
.lz_literal
			jsr .lz_length
			tax
			beq .lz_l_page_			;happens very seldom, so let's do that with lz_l_page that also decrements lz_len_hi, it returns on c = 1, what is always true after jsr .lz_length
.lz_cp_lit
			lda (lz_src),y			;looks expensive, but is cheaper than loop
			sta (lz_dst),y
			iny
			dex
			bne .lz_cp_lit

							;works only as standalone depacker, not if we do a loadcompd, as the literal copy might read data not yet loaded, due to missing checks
			dey				;this way we force increment of lz_src + 1 if y = 0
			tya				;carry is still set on first round
			adc <lz_dst + 0
			sta <lz_dst + 0		;XXX TODO final add of y, could be combined with next add? -> postpone until match that will happen necessarily later on? but this could be called mutliple times for several pages? :-(
			bcc +				;XXX TODO branch out and reenter
			inc <lz_dst + 1
+
			tya
			sec				;XXX TODO meh, setting carry ...
			adc <lz_src + 0
			sta <lz_src + 0
			bcc +
			inc <lz_src + 1
+
			ldy <lz_len_hi			;more pages to copy?
			bne .lz_l_page			;happens very seldom

			;------------------
			;NEW OR OLD OFFSET
			;------------------
							;in case of type bit == 0 we can always receive length (not length - 1), can this used for an optimization? can we fetch length beforehand? and then fetch offset? would make length fetch simpler? place some other bit with offset?
			lda #$01			;same code as above, meh
			+get_lz_bit
			bcs .lz_match			;either match with new offset or old offset

			;------------------
			;DO MATCH
			;------------------
.lz_repeat
			jsr .lz_length
			sbc #$01
			bcc .lz_dcp			;XXX TODO in fact we could save on the sbc #$01 as the sec and adc later on corrects that again, but y would turn out one too less
.lz_match_big						;we enter with length - 1 here from normal match
			eor #$ff
			tay
							;XXX TODO save on eor #$ff and do sbclz_dst + 0?
			eor #$ff			;restore A
.lz_match_len2						;entry from new_offset handling
			adc <lz_dst + 0
			sta <lz_dst + 0
			bcs .lz_clc			;/!\ branch happens very seldom, if so, clear carry
			dec <lz_dst + 1			;subtract one more in this case
.lz_clc_back
.lz_offset_lo		sbc #$00			;carry is cleared, subtract (offset + 1) in fact we could use sbx here, but would not respect carry, but a and x are same, but need x later anyway for other purpose
			sta .lz_msrcr + 0
			lax <lz_dst + 1
.lz_offset_hi		sbc #$00
			sta .lz_msrcr + 1
.lz_cp_match
			;XXX TODO if repeated offset: add literal size to .lz_msrcr and done?
.lz_msrcr = * + 1
			lda $beef,y
			sta (lz_dst),y
			iny
			bne .lz_cp_match
			inx
			stx <lz_dst + 1

			lda <lz_len_hi			;check for more loop runs
			bne .lz_m_page			;do more page runs? Yes? Fall through

			cpx <lz_src + 1
			bne .lz_start_over		;we could check against src >= dst XXX TODO
			ldx <lz_dst + 0			;check for end condition when depacking inplace, lz_dst + 0 still in X
			cpx <lz_src + 0
			bne .lz_start_over
			rts				;if lz_src + 1 gets incremented, the barrier check hits in even later, so at least one block is loaded, if it was $ff, we at least load the last block @ $ffxx, it must be the last block being loaded anyway

			;------------------
			;SELDOM STUFF
			;------------------
.lz_l_page
			sec				;only needs to be set for consecutive rounds of literals, happens very seldom
			ldy #$00
.lz_l_page_
			dec <lz_len_hi
			bcs .lz_cp_lit
.lz_clc
			clc
			bcc .lz_clc_back
.lz_m_page
			lda #$ff
.lz_dcp
			dcp lz_len_hi
			bcs .lz_match_big

			;------------------
			;FETCH A NEW OFFSET
			;------------------
-							;lz_length as inline
			+get_lz_bit			;fetch payload bit
			rol				;can also moved to front and executed once on start
.lz_match
			+get_lz_bit
			bcc -

			bne +
			jsr .lz_refill_bits
+
			sbc #$01			;XXX TODO can be omitted if just endposition is checked, but 0 does not exist as value?
			bcc .lz_eof			;underflow. must have been 0

			lsr
			sta .lz_offset_hi + 1		;hibyte of offset

			lda (lz_src),y			;fetch another byte directly
			ror
			sta .lz_offset_lo + 1

			inc <lz_src + 0			;postponed, so no need to save A on next_page call
			beq .lz_inc_src1
.lz_inc_src1_
			lda #$01
			ldy #$fe
			bcs .lz_match_len2		;length = 2 ^ $ff, do it the very short way :-)
-
			+get_lz_bit			;fetch first payload bit
							;XXX TODO we could check bit 7 before further asl?
			rol				;can also moved to front and executed once on start
			+get_lz_bit
			bcc -
			bne .lz_match_big
			ldy #$00			;only now y = 0 is needed
			jsr .lz_refill_bits		;fetch remaining bits
			bcs .lz_match_big

			;------------------
			;POINTER HIGHBYTE HANDLING
			;------------------
.lz_inc_src1
			inc <lz_src + 1			;preserves carry, all sane
			bne .lz_inc_src1_
.lz_inc_src2
			inc <lz_src + 1			;preserves carry and A, clears X, Y, all sane
			bne .lz_inc_src2_

			;------------------
			;ELIAS FETCH
			;------------------
.lz_refill_bits
			tax
			lda (lz_src),y
			+set_lz_bit_marker
			sta <lz_bits
			inc <lz_src + 0 		;postponed, so no need to save A on next_page call
			beq .lz_inc_src2		;XXX TODO if we would prefer beq, 0,2% saving
.lz_inc_src2_
			txa
			bcs .lz_lend

.lz_get_loop
			+get_lz_bit			;fetch payload bit
.lz_length_16_
			rol				;can also moved to front and executed once on start
			bcs .lz_length_16		;first 1 drops out from lowbyte, need to extend to 16 bit, unfortunatedly this does not work with inverted numbers
.lz_length
			+get_lz_bit

			bcc .lz_get_loop
			beq .lz_refill_bits
.lz_lend
.lz_eof
			rts
.lz_length_16						;happens very rarely
			pha				;save LSB
			tya				;was lda #$01, but A = 0 + rol makes this also start with MSB = 1
			jsr .lz_length_16_		;get up to 7 more bits
			sta <lz_len_hi			;save MSB
			pla				;restore LSB
			rts
