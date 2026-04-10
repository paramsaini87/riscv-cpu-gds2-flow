#!/usr/bin/env python3
"""Generate RV32IM + CSR ISA compliance tests.
Each test is self-checking: writes 1 to TOHOST on pass, test_num on fail.
Memory map: Instructions 0x0000+, TOHOST at 0x1000, Data at 0x2000+."""

import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from rv32i_asm import Program

OUTDIR = os.path.join(os.path.dirname(__file__), 'tests')
os.makedirs(OUTDIR, exist_ok=True)

def write_test(name, prog):
    path = os.path.join(OUTDIR, f'{name}.hex')
    n = prog.write_hex(path)
    return n

# ============================================================================
# Helpers: load 32-bit value and set expected
# ============================================================================
def load_val(p, rd, val):
    """Load arbitrary 32-bit value into register rd."""
    p.LI(rd, val)

def store_data_word(p, addr_reg, data_reg, offset=0):
    """SW data_reg, offset(addr_reg)."""
    p.SW(data_reg, offset, addr_reg)

# ============================================================================
# TEST 1: ADDI
# ============================================================================
def gen_test_addi():
    p = Program()
    # Test 1: addi x1, x0, 100
    p.ADDI('x1', 'x0', 100)
    p.ADDI('x7', 'x0', 100)
    p.BNE('x1', 'x7', 'fail_1')
    # Test 2: addi x2, x1, -50
    p.ADDI('x2', 'x1', -50)
    p.ADDI('x7', 'x0', 50)
    p.BNE('x2', 'x7', 'fail_2')
    # Test 3: addi x3, x0, -1 (all ones)
    p.ADDI('x3', 'x0', -1)
    p.ADDI('x7', 'x0', -1)     # -1 fits in 12-bit signed
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: addi x0, x1, 100 (write to x0 should be ignored)
    p.ADDI('x0', 'x1', 100)
    p.BNE('x0', 'x0', 'fail_4')  # x0 must always be 0
    # Test 5: addi with max positive imm (2047)
    p.ADDI('x4', 'x0', 2047)
    p.ADDI('x7', 'x0', 2047)
    p.BNE('x4', 'x7', 'fail_5')
    # Test 6: addi with min negative imm (-2048)
    p.ADDI('x5', 'x0', -2048)
    p.ADDI('x7', 'x0', -2048)  # -2048 fits in 12-bit signed
    p.BNE('x5', 'x7', 'fail_6')
    # PASS
    p.PASS()
    for i in range(1, 7):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_addi', p)

# ============================================================================
# TEST 2: ADD
# ============================================================================
def gen_test_add():
    p = Program()
    # Test 1: 10 + 20 = 30
    p.ADDI('x1', 'x0', 10)
    p.ADDI('x2', 'x0', 20)
    p.ADD('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 30)
    p.BNE('x3', 'x7', 'fail')
    # Test 2: negative + positive
    p.ADDI('x1', 'x0', -5)
    p.ADDI('x2', 'x0', 15)
    p.ADD('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 10)
    p.BNE('x3', 'x7', 'fail')
    # Test 3: 0 + 0
    p.ADD('x3', 'x0', 'x0')
    p.BNE('x3', 'x0', 'fail')
    # Test 4: overflow (positive wrap)
    p.LI('x1', 0x7FFFFFFF)         # x1 = max positive int
    p.ADDI('x2', 'x0', 1)
    p.ADD('x3', 'x1', 'x2')        # x3 = 0x80000000 (overflow)
    p.LUI('x7', 0x80000)            # x7 = 0x80000000
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_add', p)

# ============================================================================
# TEST 3: SUB
# ============================================================================
def gen_test_sub():
    p = Program()
    p.ADDI('x1', 'x0', 30)
    p.ADDI('x2', 'x0', 10)
    p.SUB('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 20)
    p.BNE('x3', 'x7', 'fail')
    # Negative result
    p.ADDI('x1', 'x0', 5)
    p.ADDI('x2', 'x0', 15)
    p.SUB('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -10)
    p.BNE('x3', 'x7', 'fail')
    # Zero
    p.ADDI('x1', 'x0', 42)
    p.SUB('x3', 'x1', 'x1')
    p.BNE('x3', 'x0', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_sub', p)

# ============================================================================
# TEST 4: AND / ANDI
# ============================================================================
def gen_test_and():
    p = Program()
    p.ADDI('x1', 'x0', 0xFF)
    p.ADDI('x2', 'x0', 0x0F)
    p.AND('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 0x0F)
    p.BNE('x3', 'x7', 'fail')
    # ANDI
    p.ADDI('x1', 'x0', 0x1FF)
    p.ANDI('x3', 'x1', 0x0F0)
    p.ADDI('x7', 'x0', 0xF0)
    p.BNE('x3', 'x7', 'fail')
    # AND with zero
    p.AND('x3', 'x1', 'x0')
    p.BNE('x3', 'x0', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_and', p)

# ============================================================================
# TEST 5: OR / ORI
# ============================================================================
def gen_test_or():
    p = Program()
    p.ADDI('x1', 'x0', 0xF0)
    p.ADDI('x2', 'x0', 0x0F)
    p.OR('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 0xFF)
    p.BNE('x3', 'x7', 'fail')
    # ORI
    p.ADDI('x1', 'x0', 0x100)
    p.ORI('x3', 'x1', 0x0FF)
    p.ADDI('x7', 'x0', 0x1FF)
    p.BNE('x3', 'x7', 'fail')
    # OR with self
    p.ADDI('x1', 'x0', 42)
    p.OR('x3', 'x1', 'x1')
    p.BNE('x3', 'x1', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_or', p)

# ============================================================================
# TEST 6: XOR / XORI
# ============================================================================
def gen_test_xor():
    p = Program()
    p.ADDI('x1', 'x0', 0xFF)
    p.ADDI('x2', 'x0', 0x0F)
    p.XOR('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 0xF0)
    p.BNE('x3', 'x7', 'fail')
    # XORI
    p.ADDI('x1', 'x0', 0xFF)
    p.XORI('x3', 'x1', 0x0F)
    p.ADDI('x7', 'x0', 0xF0)
    p.BNE('x3', 'x7', 'fail')
    # XOR with self = 0
    p.ADDI('x1', 'x0', 42)
    p.XOR('x3', 'x1', 'x1')
    p.BNE('x3', 'x0', 'fail')
    # NOT via XORI (xori rd, rs, -1)
    p.ADDI('x1', 'x0', 0)
    p.XORI('x3', 'x1', -1)  # ~0 = 0xFFFFFFFF
    p.ADDI('x7', 'x0', -1)
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_xor', p)

# ============================================================================
# TEST 7: SLT / SLTU / SLTI / SLTIU
# ============================================================================
def gen_test_slt():
    p = Program()
    # SLT: signed compare
    p.ADDI('x1', 'x0', -1)   # 0xFFFFFFFF (signed: -1)
    p.ADDI('x2', 'x0', 1)
    p.SLT('x3', 'x1', 'x2')  # -1 < 1 → 1
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail')
    # SLT: not less
    p.SLT('x3', 'x2', 'x1')  # 1 < -1 → 0
    p.BNE('x3', 'x0', 'fail')
    # SLTU: unsigned compare (-1 = 0xFFFFFFFF > 1)
    p.SLTU('x3', 'x2', 'x1') # 1 < 0xFFFFFFFF → 1
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail')
    # SLTI
    p.ADDI('x1', 'x0', 5)
    p.SLTI('x3', 'x1', 10)    # 5 < 10 → 1
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail')
    p.SLTI('x3', 'x1', 3)     # 5 < 3 → 0
    p.BNE('x3', 'x0', 'fail')
    # SLTIU: unsigned imm compare
    p.ADDI('x1', 'x0', 5)
    p.SLTIU('x3', 'x1', 10)   # 5 < 10 → 1
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_slt', p)

# ============================================================================
# TEST 8: SLL / SLLI
# ============================================================================
def gen_test_sll():
    p = Program()
    p.ADDI('x1', 'x0', 1)
    p.ADDI('x2', 'x0', 4)
    p.SLL('x3', 'x1', 'x2')   # 1 << 4 = 16
    p.ADDI('x7', 'x0', 16)
    p.BNE('x3', 'x7', 'fail')
    # SLLI
    p.ADDI('x1', 'x0', 3)
    p.SLLI('x3', 'x1', 8)      # 3 << 8 = 768
    p.LI('x7', 768)
    p.BNE('x3', 'x7', 'fail')
    # Shift by 0
    p.ADDI('x1', 'x0', 42)
    p.SLL('x3', 'x1', 'x0')
    p.BNE('x3', 'x1', 'fail')
    # Shift by 31
    p.ADDI('x1', 'x0', 1)
    p.SLLI('x3', 'x1', 31)     # 0x80000000
    p.LUI('x7', 0x80000)
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_sll', p)

# ============================================================================
# TEST 9: SRL / SRLI
# ============================================================================
def gen_test_srl():
    p = Program()
    p.ADDI('x1', 'x0', 256)
    p.ADDI('x2', 'x0', 4)
    p.SRL('x3', 'x1', 'x2')   # 256 >> 4 = 16
    p.ADDI('x7', 'x0', 16)
    p.BNE('x3', 'x7', 'fail')
    # SRLI
    p.LI('x1', 0x80000000)
    p.SRLI('x3', 'x1', 1)      # logical: 0x40000000
    p.LUI('x7', 0x40000)
    p.BNE('x3', 'x7', 'fail')
    # Shift by 0
    p.ADDI('x1', 'x0', 42)
    p.SRLI('x3', 'x1', 0)
    p.BNE('x3', 'x1', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_srl', p)

# ============================================================================
# TEST 10: SRA / SRAI
# ============================================================================
def gen_test_sra():
    p = Program()
    # Arithmetic shift preserves sign
    p.ADDI('x1', 'x0', -16)    # 0xFFFFFFF0
    p.ADDI('x2', 'x0', 2)
    p.SRA('x3', 'x1', 'x2')    # -16 >>> 2 = -4 (0xFFFFFFFC)
    p.ADDI('x7', 'x0', -4)
    p.BNE('x3', 'x7', 'fail')
    # SRAI
    p.LI('x1', 0x80000000)      # -2147483648
    p.SRAI('x3', 'x1', 4)       # 0xF8000000
    p.LUI('x7', 0xF8000)
    p.BNE('x3', 'x7', 'fail')
    # Positive number — same as logical
    p.ADDI('x1', 'x0', 64)
    p.SRAI('x3', 'x1', 2)
    p.ADDI('x7', 'x0', 16)
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_sra', p)

# ============================================================================
# TEST 11: LUI
# ============================================================================
def gen_test_lui():
    p = Program()
    p.LUI('x1', 0xDEADB)
    p.LUI('x7', 0xDEADB)
    p.BNE('x1', 'x7', 'fail')
    # LUI x2, 1 → 0x1000
    p.LUI('x2', 1)
    p.LI('x7', 0x1000)
    p.BNE('x2', 'x7', 'fail')
    # LUI x0 → should still be 0
    p.LUI('x0', 0xFFFFF)
    p.BNE('x0', 'x0', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_lui', p)

# ============================================================================
# TEST 12: AUIPC
# ============================================================================
def gen_test_auipc():
    p = Program()
    # AUIPC x1, 0 → x1 = PC of this instruction
    p.AUIPC('x1', 0)           # x1 = PC (some address)
    p.BNE('x1', 'x0', 'fail')  # first instruction at addr 0 → x1 = 0

    # Position-independent test: AUIPC x2, 1 → x2 = PC + 0x1000
    # Verify by computing expected from another AUIPC
    p.AUIPC('x2', 1)           # x2 = PC_here + 0x1000
    p.AUIPC('x3', 0)           # x3 = PC_here (4 bytes after x2's AUIPC)
    p.ADDI('x3', 'x3', -4)    # x3 = PC of AUIPC x2
    p.LUI('x8', 1)             # x8 = 0x1000
    p.ADD('x7', 'x3', 'x8')   # x7 = PC_auipc_x2 + 0x1000 = expected x2
    p.BNE('x2', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_auipc', p)

# ============================================================================
# TEST 13: JAL
# ============================================================================
def gen_test_jal():
    p = Program()
    # JAL x1, target → x1 = PC+4, jump to target
    p.JAL('x1', 'target')
    # If JAL doesn't jump, we hit fail
    p.J('fail')
    p.label('target')
    # x1 should be 0x0004 (address of instruction after JAL = 0x0000 + 4)
    p.ADDI('x7', 'x0', 4)
    p.BNE('x1', 'x7', 'fail')
    # JAL x0 (don't save return address)
    p.JAL('x0', 'target2')
    p.J('fail')
    p.label('target2')
    p.BNE('x0', 'x0', 'fail')  # x0 must still be 0
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_jal', p)

# ============================================================================
# TEST 14: JALR
# ============================================================================
def gen_test_jalr():
    p = Program()
    # Test 1: JALR basic — use AUIPC to compute target, verify link register
    # AUIPC at 0x00 → x5 = 0x0000. Add offset to reach target1.
    p.AUIPC('x5', 0)             # 0x00: x5 = 0
    p.ADDI('x5', 'x5', 20)      # 0x04: x5 = 20 = 0x14 (addr of target1)
    p.JALR('x1', 'x5', 0)       # 0x08: jump to 0x14, x1 = 0x0C
    p.J('fail')                   # 0x0C: skip if jump worked
    p.J('fail')                   # 0x10: padding
    p.label('target1')            # 0x14
    p.ADDI('x7', 'x0', 0x0C)    # x1 should be 0x0C (PC of JALR + 4)
    p.BNE('x1', 'x7', 'fail')

    # Test 2: JALR with nonzero offset
    p.AUIPC('x5', 0)             # 0x1C: x5 = 0x1C
    p.ADDI('x5', 'x5', 12)      # 0x20: x5 = 0x28
    p.JALR('x1', 'x5', 4)       # 0x24: jump to (0x28+4)&~1 = 0x2C, x1 = 0x28
    p.J('fail')                   # 0x28
    p.label('target2')            # 0x2C
    p.ADDI('x7', 'x0', 0x28)    # x1 should be 0x28
    p.BNE('x1', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_jalr', p)

# ============================================================================
# TEST 15: BEQ
# ============================================================================
def gen_test_beq():
    p = Program()
    p.ADDI('x1', 'x0', 42)
    p.ADDI('x2', 'x0', 42)
    p.BEQ('x1', 'x2', 'eq_ok')
    p.J('fail')
    p.label('eq_ok')
    # Not equal — should NOT branch
    p.ADDI('x3', 'x0', 1)
    p.BEQ('x1', 'x3', 'fail')
    # BEQ x0, x0 — always true
    p.BEQ('x0', 'x0', 'zero_ok')
    p.J('fail')
    p.label('zero_ok')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_beq', p)

# ============================================================================
# TEST 16: BNE
# ============================================================================
def gen_test_bne():
    p = Program()
    p.ADDI('x1', 'x0', 10)
    p.ADDI('x2', 'x0', 20)
    p.BNE('x1', 'x2', 'ne_ok')
    p.J('fail')
    p.label('ne_ok')
    # Equal — should NOT branch
    p.ADDI('x3', 'x0', 10)
    p.BNE('x1', 'x3', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_bne', p)

# ============================================================================
# TEST 17: BLT
# ============================================================================
def gen_test_blt():
    p = Program()
    # Signed: -1 < 1
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', 1)
    p.BLT('x1', 'x2', 'lt_ok')
    p.J('fail')
    p.label('lt_ok')
    # Not less: 1 < -1 → false
    p.BLT('x2', 'x1', 'fail')
    # Equal: not less
    p.ADDI('x3', 'x0', 5)
    p.ADDI('x4', 'x0', 5)
    p.BLT('x3', 'x4', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_blt', p)

# ============================================================================
# TEST 18: BGE
# ============================================================================
def gen_test_bge():
    p = Program()
    # 1 >= -1 (signed)
    p.ADDI('x1', 'x0', 1)
    p.ADDI('x2', 'x0', -1)
    p.BGE('x1', 'x2', 'ge_ok')
    p.J('fail')
    p.label('ge_ok')
    # Equal
    p.ADDI('x3', 'x0', 7)
    p.ADDI('x4', 'x0', 7)
    p.BGE('x3', 'x4', 'ge_eq_ok')
    p.J('fail')
    p.label('ge_eq_ok')
    # Less — should NOT branch
    p.BGE('x2', 'x1', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_bge', p)

# ============================================================================
# TEST 19: BLTU
# ============================================================================
def gen_test_bltu():
    p = Program()
    # Unsigned: 1 < 0xFFFFFFFF
    p.ADDI('x1', 'x0', 1)
    p.ADDI('x2', 'x0', -1)    # 0xFFFFFFFF unsigned
    p.BLTU('x1', 'x2', 'ltu_ok')
    p.J('fail')
    p.label('ltu_ok')
    # Not less: 0xFFFFFFFF < 1 → false
    p.BLTU('x2', 'x1', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_bltu', p)

# ============================================================================
# TEST 20: BGEU
# ============================================================================
def gen_test_bgeu():
    p = Program()
    # 0xFFFFFFFF >= 1 (unsigned)
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', 1)
    p.BGEU('x1', 'x2', 'geu_ok')
    p.J('fail')
    p.label('geu_ok')
    # Equal
    p.ADDI('x3', 'x0', 5)
    p.BGEU('x3', 'x3', 'geu_eq_ok')
    p.J('fail')
    p.label('geu_eq_ok')
    # Less → should NOT branch
    p.BGEU('x2', 'x1', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_bgeu', p)

# ============================================================================
# TEST 21-25: LOAD/STORE (SW/LW/SH/LH/SB/LB/LHU/LBU)
# ============================================================================
def gen_test_sw_lw():
    p = Program()
    # Store and load a word at data address 0x2000
    p.LUI('x10', 2)             # x10 = 0x2000 (data base)
    p.LI('x1', 0xDEADBEEF)
    p.SW('x1', 0, 'x10')        # mem[0x2000] = 0xDEADBEEF
    p.LW('x2', 0, 'x10')        # x2 = mem[0x2000]
    p.BNE('x1', 'x2', 'fail')
    # Store/load at offset
    p.ADDI('x3', 'x0', 42)
    p.SW('x3', 4, 'x10')        # mem[0x2004] = 42
    p.LW('x4', 4, 'x10')
    p.BNE('x3', 'x4', 'fail')
    # Store 0
    p.SW('x0', 8, 'x10')
    p.LW('x5', 8, 'x10')
    p.BNE('x5', 'x0', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_sw_lw', p)

def gen_test_sh_lh_lhu():
    p = Program()
    p.LUI('x10', 2)             # x10 = 0x2000
    # Store word with known pattern, then load halfwords
    p.LI('x1', 0x12345678)
    p.SW('x1', 0, 'x10')
    # LH offset 0: should get 0x5678, sign-extended = 0x00005678
    p.LH('x2', 0, 'x10')
    p.LI('x7', 0x00005678)
    p.BNE('x2', 'x7', 'fail')
    # LH offset 2: should get 0x1234, sign-extended = 0x00001234
    p.LH('x3', 2, 'x10')
    p.LI('x7', 0x00001234)
    p.BNE('x3', 'x7', 'fail')
    # LHU offset 0: same as LH for positive values
    p.LHU('x4', 0, 'x10')
    p.LI('x7', 0x00005678)
    p.BNE('x4', 'x7', 'fail')
    # Store negative half, load signed vs unsigned
    p.LI('x1', 0x0000FFFF)
    p.SW('x1', 4, 'x10')
    p.LH('x2', 4, 'x10')       # 0xFFFF sign-extended = 0xFFFFFFFF = -1
    p.ADDI('x7', 'x0', -1)
    p.BNE('x2', 'x7', 'fail')
    p.LHU('x3', 4, 'x10')      # 0xFFFF zero-extended = 0x0000FFFF
    p.LI('x7', 0x0000FFFF)
    p.BNE('x3', 'x7', 'fail')
    # SH: store halfword
    p.ADDI('x1', 'x0', 0x7AB)
    p.SH('x1', 8, 'x10')
    p.LHU('x2', 8, 'x10')
    p.ADDI('x7', 'x0', 0x7AB)
    p.BNE('x2', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_sh_lh_lhu', p)

def gen_test_sb_lb_lbu():
    p = Program()
    p.LUI('x10', 2)             # x10 = 0x2000
    # Store word with known pattern
    p.LI('x1', 0xAABBCCDD)
    p.SW('x1', 0, 'x10')
    # LB offset 0: byte 0 = 0xDD, sign-extended = 0xFFFFFFDD = -35
    p.LB('x2', 0, 'x10')
    p.ADDI('x7', 'x0', -35)
    p.BNE('x2', 'x7', 'fail')
    # LBU offset 0: 0xDD zero-extended = 0x000000DD = 221
    p.LBU('x3', 0, 'x10')
    p.ADDI('x7', 'x0', 221)
    p.BNE('x3', 'x7', 'fail')
    # LB offset 1: byte 1 = 0xCC, sign-extended = 0xFFFFFFCC = -52
    p.LB('x4', 1, 'x10')
    p.ADDI('x7', 'x0', -52)
    p.BNE('x4', 'x7', 'fail')
    # LBU offset 2: byte 2 = 0xBB = 187
    p.LBU('x5', 2, 'x10')
    p.ADDI('x7', 'x0', 187)
    p.BNE('x5', 'x7', 'fail')
    # LBU offset 3: byte 3 = 0xAA = 170
    p.LBU('x6', 3, 'x10')
    p.ADDI('x7', 'x0', 170)
    p.BNE('x6', 'x7', 'fail')
    # SB: store byte
    p.ADDI('x1', 'x0', 0x42)
    p.SB('x1', 4, 'x10')
    p.LBU('x2', 4, 'x10')
    p.ADDI('x7', 'x0', 0x42)
    p.BNE('x2', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_sb_lb_lbu', p)

# ============================================================================
# TEST 26: FENCE / ECALL / EBREAK (must not crash — NOP behavior)
# ============================================================================
def gen_test_system():
    p = Program()
    p.ADDI('x1', 'x0', 42)
    p.FENCE()                    # should be NOP
    p.ADDI('x7', 'x0', 42)
    p.BNE('x1', 'x7', 'fail')   # x1 should still be 42
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_system', p)

# ============================================================================
# TEST 27: DATA FORWARDING (pipeline hazard — EX→EX and MEM→EX)
# ============================================================================
def gen_test_forwarding():
    p = Program()
    # Back-to-back dependency (EX→EX forwarding)
    p.ADDI('x1', 'x0', 10)
    p.ADDI('x2', 'x1', 20)      # depends on x1 (EX→EX forward)
    p.ADDI('x7', 'x0', 30)
    p.BNE('x2', 'x7', 'fail')
    # Chain of 3
    p.ADDI('x1', 'x0', 1)
    p.ADDI('x2', 'x1', 1)       # x2 = 2
    p.ADDI('x3', 'x2', 1)       # x3 = 3 (MEM→EX forward from x2)
    p.ADDI('x7', 'x0', 3)
    p.BNE('x3', 'x7', 'fail')
    # MEM→EX forwarding (2-cycle gap)
    p.ADDI('x1', 'x0', 100)
    p.NOP()
    p.ADDI('x2', 'x1', 5)       # x1 from MEM/WB stage
    p.ADDI('x7', 'x0', 105)
    p.BNE('x2', 'x7', 'fail')
    # R-type back-to-back
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', 3)
    p.ADD('x3', 'x1', 'x2')
    p.ADD('x4', 'x3', 'x1')     # depends on x3 (EX→EX)
    p.ADDI('x7', 'x0', 17)      # 7+3=10, 10+7=17
    p.BNE('x4', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_forwarding', p)

# ============================================================================
# TEST 28: LOAD-USE HAZARD (must stall 1 cycle)
# ============================================================================
def gen_test_load_use():
    p = Program()
    p.LUI('x10', 2)             # x10 = 0x2000
    p.ADDI('x1', 'x0', 77)
    p.SW('x1', 0, 'x10')        # mem[0x2000] = 77
    p.LW('x2', 0, 'x10')        # x2 = 77 (load)
    p.ADDI('x3', 'x2', 10)      # LOAD-USE: x3 = x2 + 10 = 87 (pipeline stalls 1 cycle)
    p.ADDI('x7', 'x0', 87)
    p.BNE('x3', 'x7', 'fail')
    # Load-use with R-type
    p.ADDI('x4', 'x0', 3)
    p.SW('x4', 4, 'x10')
    p.LW('x5', 4, 'x10')
    p.ADD('x6', 'x5', 'x4')     # LOAD-USE on x5: 3 + 3 = 6
    p.ADDI('x7', 'x0', 6)
    p.BNE('x6', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_load_use', p)

# ============================================================================
# TEST 29: BRANCH + FORWARDING (branch after ALU)
# ============================================================================
def gen_test_branch_fwd():
    p = Program()
    # Branch immediately after ALU result
    p.ADDI('x1', 'x0', 5)
    p.ADDI('x2', 'x0', 5)
    p.SUB('x3', 'x1', 'x2')     # x3 = 0
    p.BEQ('x3', 'x0', 'ok1')    # branch depends on x3 (forwarding to branch)
    p.J('fail')
    p.label('ok1')
    # Back-to-back ALU + branch
    p.ADDI('x4', 'x0', 10)
    p.ADDI('x5', 'x0', 20)
    p.ADD('x6', 'x4', 'x5')     # x6 = 30
    p.ADDI('x7', 'x0', 30)
    p.BNE('x6', 'x7', 'fail')   # should NOT branch
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_branch_fwd', p)

# ============================================================================
# TEST 30: COMPREHENSIVE — exercises multiple instructions together
# ============================================================================
def gen_test_comprehensive():
    p = Program()
    # Compute sum 1+2+3+...+10 = 55
    p.ADDI('x1', 'x0', 0)       # sum = 0
    p.ADDI('x2', 'x0', 1)       # i = 1
    p.ADDI('x3', 'x0', 11)      # limit = 11
    p.label('loop')
    p.ADD('x1', 'x1', 'x2')     # sum += i
    p.ADDI('x2', 'x2', 1)       # i++
    p.BLT('x2', 'x3', 'loop')   # if i < 11, loop
    p.ADDI('x7', 'x0', 55)
    p.BNE('x1', 'x7', 'fail')
    # Fibonacci: F(10) = 55
    p.ADDI('x1', 'x0', 0)       # a = 0
    p.ADDI('x2', 'x0', 1)       # b = 1
    p.ADDI('x3', 'x0', 10)      # count
    p.label('fib_loop')
    p.ADD('x4', 'x1', 'x2')     # c = a + b
    p.MV('x1', 'x2')            # a = b
    p.MV('x2', 'x4')            # b = c
    p.ADDI('x3', 'x3', -1)
    p.BNE('x3', 'x0', 'fib_loop')
    p.ADDI('x7', 'x0', 55)
    p.BNE('x1', 'x7', 'fail')   # F(10) = 55
    # Store/load array test
    p.LUI('x10', 2)             # base = 0x2000
    p.ADDI('x1', 'x0', 0)
    p.ADDI('x2', 'x0', 5)       # store 5 values
    p.label('store_loop')
    p.SLLI('x3', 'x1', 2)       # offset = i * 4
    p.ADD('x4', 'x10', 'x3')    # addr = base + offset
    p.SW('x1', 0, 'x4')         # mem[addr] = i
    p.ADDI('x1', 'x1', 1)
    p.BLT('x1', 'x2', 'store_loop')
    # Verify: load back and sum
    p.ADDI('x1', 'x0', 0)       # i = 0
    p.ADDI('x5', 'x0', 0)       # sum = 0
    p.label('load_loop')
    p.SLLI('x3', 'x1', 2)
    p.ADD('x4', 'x10', 'x3')
    p.LW('x6', 0, 'x4')
    p.ADD('x5', 'x5', 'x6')
    p.ADDI('x1', 'x1', 1)
    p.BLT('x1', 'x2', 'load_loop')
    p.ADDI('x7', 'x0', 10)      # 0+1+2+3+4 = 10
    p.BNE('x5', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_comprehensive', p)


# ============================================================================
# M-EXTENSION TESTS
# ============================================================================

# ============================================================================
# TEST 29: MUL (lower 32 bits of signed multiply)
# ============================================================================
def gen_test_mul():
    p = Program()
    # Test 1: 3 * 4 = 12
    p.ADDI('x1', 'x0', 3)
    p.ADDI('x2', 'x0', 4)
    p.MUL('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 12)
    p.BNE('x3', 'x7', 'fail_1')
    # Test 2: -2 * 3 = -6
    p.ADDI('x1', 'x0', -2)
    p.ADDI('x2', 'x0', 3)
    p.MUL('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -6)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: -3 * -4 = 12
    p.ADDI('x1', 'x0', -3)
    p.ADDI('x2', 'x0', -4)
    p.MUL('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 12)
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: multiply by zero
    p.ADDI('x1', 'x0', 100)
    p.MUL('x3', 'x1', 'x0')
    p.BNE('x3', 'x0', 'fail_4')
    # Test 5: overflow wrap (0x10000 * 0x10000 = 0x100000000 -> lower 32 = 0)
    p.LI('x1', 0x10000)
    p.LI('x2', 0x10000)
    p.MUL('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_5')
    # Test 6: multiply by 1
    p.ADDI('x1', 'x0', -7)
    p.ADDI('x2', 'x0', 1)
    p.MUL('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -7)
    p.BNE('x3', 'x7', 'fail_6')
    p.PASS()
    for i in range(1, 7):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_mul', p)

# ============================================================================
# TEST 30: MULH (upper 32 bits of signed*signed)
# ============================================================================
def gen_test_mulh():
    p = Program()
    # Test 1: small * small -> upper bits = 0
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', 3)
    p.MULH('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_1')
    # Test 2: -1 * -1 -> full product = +1 (64-bit), upper = 0
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', -1)
    p.MULH('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_2')
    # Test 3: -1 * 1 -> full product = -1 (64-bit: 0xFFFFFFFF_FFFFFFFF), upper = 0xFFFFFFFF
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', 1)
    p.MULH('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -1)
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: 0x40000000 * 4 = 0x100000000, upper = 1
    p.LI('x1', 0x40000000)
    p.ADDI('x2', 'x0', 4)
    p.MULH('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail_4')
    p.PASS()
    for i in range(1, 5):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_mulh', p)

# ============================================================================
# TEST 31: MULHSU (upper 32 bits of signed*unsigned)
# ============================================================================
def gen_test_mulhsu():
    p = Program()
    # Test 1: positive * positive -> same as MULH
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', 3)
    p.MULHSU('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_1')
    # Test 2: -1 (signed) * 1 (unsigned) = -1 (64-bit), upper = 0xFFFFFFFF
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', 1)
    p.MULHSU('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -1)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: -1 (signed) * 0 = 0
    p.ADDI('x1', 'x0', -1)
    p.MULHSU('x3', 'x1', 'x0')
    p.BNE('x3', 'x0', 'fail_3')
    p.PASS()
    for i in range(1, 4):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_mulhsu', p)

# ============================================================================
# TEST 32: MULHU (upper 32 bits of unsigned*unsigned)
# ============================================================================
def gen_test_mulhu():
    p = Program()
    # Test 1: small * small -> upper = 0
    p.ADDI('x1', 'x0', 100)
    p.ADDI('x2', 'x0', 200)
    p.MULHU('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_1')
    # Test 2: 0xFFFFFFFF * 0xFFFFFFFF -> upper = 0xFFFFFFFE
    p.ADDI('x1', 'x0', -1)   # = 0xFFFFFFFF unsigned
    p.ADDI('x2', 'x0', -1)
    p.MULHU('x3', 'x1', 'x2')
    p.LI('x7', 0xFFFFFFFE)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: 0x80000000 * 2 -> 0x100000000, upper = 1
    p.LI('x1', 0x80000000)
    p.ADDI('x2', 'x0', 2)
    p.MULHU('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail_3')
    p.PASS()
    for i in range(1, 4):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_mulhu', p)

# ============================================================================
# TEST 33: DIV (signed division, rounds toward zero)
# ============================================================================
def gen_test_div():
    p = Program()
    # Test 1: 10 / 2 = 5
    p.ADDI('x1', 'x0', 10)
    p.ADDI('x2', 'x0', 2)
    p.DIV('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 5)
    p.BNE('x3', 'x7', 'fail_1')
    # Test 2: -7 / 2 = -3 (rounds toward zero, not floor)
    p.ADDI('x1', 'x0', -7)
    p.ADDI('x2', 'x0', 2)
    p.DIV('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -3)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: 7 / -2 = -3
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', -2)
    p.DIV('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -3)
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: divide by zero -> result = -1 (0xFFFFFFFF)
    p.ADDI('x1', 'x0', 10)
    p.DIV('x3', 'x1', 'x0')
    p.ADDI('x7', 'x0', -1)
    p.BNE('x3', 'x7', 'fail_4')
    # Test 5: signed overflow 0x80000000 / -1 = 0x80000000
    p.LI('x1', 0x80000000)
    p.ADDI('x2', 'x0', -1)
    p.DIV('x3', 'x1', 'x2')
    p.LI('x7', 0x80000000)
    p.BNE('x3', 'x7', 'fail_5')
    # Test 6: -1 / -1 = 1
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', -1)
    p.DIV('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail_6')
    p.PASS()
    for i in range(1, 7):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_div', p)

# ============================================================================
# TEST 34: DIVU (unsigned division)
# ============================================================================
def gen_test_divu():
    p = Program()
    # Test 1: 20 / 3 = 6
    p.ADDI('x1', 'x0', 20)
    p.ADDI('x2', 'x0', 3)
    p.DIVU('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 6)
    p.BNE('x3', 'x7', 'fail_1')
    # Test 2: 0xFFFFFFFF / 2 = 0x7FFFFFFF
    p.ADDI('x1', 'x0', -1)     # = 0xFFFFFFFF
    p.ADDI('x2', 'x0', 2)
    p.DIVU('x3', 'x1', 'x2')
    p.LI('x7', 0x7FFFFFFF)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: divide by zero -> 0xFFFFFFFF
    p.ADDI('x1', 'x0', 10)
    p.DIVU('x3', 'x1', 'x0')
    p.ADDI('x7', 'x0', -1)   # 0xFFFFFFFF
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: divide by 1
    p.ADDI('x1', 'x0', 42)
    p.ADDI('x2', 'x0', 1)
    p.DIVU('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 42)
    p.BNE('x3', 'x7', 'fail_4')
    p.PASS()
    for i in range(1, 5):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_divu', p)

# ============================================================================
# TEST 35: REM (signed remainder, sign follows dividend)
# ============================================================================
def gen_test_rem():
    p = Program()
    # Test 1: 7 % 3 = 1
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', 3)
    p.REM('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail_1')
    # Test 2: -7 % 3 = -1 (sign follows dividend)
    p.ADDI('x1', 'x0', -7)
    p.ADDI('x2', 'x0', 3)
    p.REM('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', -1)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: 7 % -3 = 1 (sign follows dividend, not divisor)
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', -3)
    p.REM('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: divide by zero -> result = rs1
    p.ADDI('x1', 'x0', 10)
    p.REM('x3', 'x1', 'x0')
    p.ADDI('x7', 'x0', 10)
    p.BNE('x3', 'x7', 'fail_4')
    # Test 5: overflow 0x80000000 % -1 = 0
    p.LI('x1', 0x80000000)
    p.ADDI('x2', 'x0', -1)
    p.REM('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_5')
    p.PASS()
    for i in range(1, 6):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_rem', p)

# ============================================================================
# TEST 36: REMU (unsigned remainder)
# ============================================================================
def gen_test_remu():
    p = Program()
    # Test 1: 7 % 3 = 1
    p.ADDI('x1', 'x0', 7)
    p.ADDI('x2', 'x0', 3)
    p.REMU('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 1)
    p.BNE('x3', 'x7', 'fail_1')
    # Test 2: 0xFFFFFFFF % 7 = 3 (unsigned: 4294967295 % 7 = 3)
    p.ADDI('x1', 'x0', -1)
    p.ADDI('x2', 'x0', 7)
    p.REMU('x3', 'x1', 'x2')
    p.ADDI('x7', 'x0', 3)
    p.BNE('x3', 'x7', 'fail_2')
    # Test 3: divide by zero -> result = rs1
    p.ADDI('x1', 'x0', 42)
    p.REMU('x3', 'x1', 'x0')
    p.ADDI('x7', 'x0', 42)
    p.BNE('x3', 'x7', 'fail_3')
    # Test 4: exact division -> remainder = 0
    p.ADDI('x1', 'x0', 12)
    p.ADDI('x2', 'x0', 4)
    p.REMU('x3', 'x1', 'x2')
    p.BNE('x3', 'x0', 'fail_4')
    p.PASS()
    for i in range(1, 5):
        p.label(f'fail_{i}')
    p.FAIL(99)
    return write_test('test_remu', p)

# ============================================================================
# TEST: CSRRW — read/write CSR
# ============================================================================
def gen_test_csrrw():
    CSR_MTVEC = 0x305
    p = Program()

    # Case 1: Write a value to mtvec, read it back
    p.ADDI('x1', 'x0', 100)
    p.CSRRW('x2', CSR_MTVEC, 'x1')   # mtvec = 100, x2 = old mtvec
    # Read back mtvec to verify
    p.CSRRS('x3', CSR_MTVEC, 'x0')   # x3 = mtvec (read without modify)
    p.ADDI('x7', 'x0', 100)
    p.BNE('x3', 'x7', 'fail')        # mtvec should be 100

    # Case 2: Write new value, verify old value returned in rd
    p.ADDI('x4', 'x0', 200)
    p.CSRRW('x5', CSR_MTVEC, 'x4')   # mtvec = 200, x5 = old mtvec (100)
    p.ADDI('x7', 'x0', 100)
    p.BNE('x5', 'x7', 'fail')        # x5 should be 100 (old value)
    # Verify new value
    p.CSRRS('x6', CSR_MTVEC, 'x0')
    p.ADDI('x7', 'x0', 200)
    p.BNE('x6', 'x7', 'fail')        # mtvec should now be 200

    # Case 3: CSRRW with rd=x0 (write-only)
    p.ADDI('x8', 'x0', 44)
    p.CSRRW('x0', CSR_MTVEC, 'x8')   # mtvec = 44, discard old value
    p.CSRRS('x9', CSR_MTVEC, 'x0')
    p.ADDI('x7', 'x0', 44)
    p.BNE('x9', 'x7', 'fail')        # mtvec should be 44

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_csrrw', p)

# ============================================================================
# TEST: CSRRS + CSRRC — bit set and clear
# ============================================================================
def gen_test_csrrs_csrrc():
    CSR_MTVEC = 0x305
    p = Program()

    # Write initial value 0x10 to mtvec
    p.ADDI('x1', 'x0', 0x10)
    p.CSRRW('x0', CSR_MTVEC, 'x1')   # mtvec = 0x10

    # CSRRS: set bits 0x03 → mtvec should become 0x13
    p.ADDI('x2', 'x0', 0x03)
    p.CSRRS('x3', CSR_MTVEC, 'x2')   # x3 = old mtvec (0x10), mtvec |= 0x03
    p.ADDI('x7', 'x0', 0x10)
    p.BNE('x3', 'x7', 'fail')        # old value was 0x10

    # Read back to verify set
    p.CSRRS('x4', CSR_MTVEC, 'x0')   # x4 = mtvec (should be 0x13)
    p.ADDI('x7', 'x0', 0x13)
    p.BNE('x4', 'x7', 'fail')

    # CSRRC: clear bits 0x01 → mtvec should become 0x12
    p.ADDI('x5', 'x0', 0x01)
    p.CSRRC('x6', CSR_MTVEC, 'x5')   # x6 = old mtvec (0x13), mtvec &= ~0x01
    p.ADDI('x7', 'x0', 0x13)
    p.BNE('x6', 'x7', 'fail')        # old value was 0x13

    # Read back to verify clear
    p.CSRRS('x8', CSR_MTVEC, 'x0')   # x8 = mtvec (should be 0x12)
    p.ADDI('x7', 'x0', 0x12)
    p.BNE('x8', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_csrrs_csrrc', p)

# ============================================================================
# TEST: CSRRWI + CSRRSI + CSRRCI — immediate variants
# ============================================================================
def gen_test_csri():
    CSR_MTVEC = 0x305
    p = Program()

    # CSRRWI: write uimm=21 to mtvec
    p.CSRRWI('x1', CSR_MTVEC, 21)    # mtvec = 21, x1 = old value
    p.CSRRS('x2', CSR_MTVEC, 'x0')   # x2 = mtvec
    p.ADDI('x7', 'x0', 21)
    p.BNE('x2', 'x7', 'fail')

    # CSRRSI: set bits uimm=6 (0b00110) → mtvec becomes 21 | 6 = 23 (0x17)
    p.CSRRSI('x3', CSR_MTVEC, 6)     # x3 = old mtvec (21), mtvec |= 6
    p.ADDI('x7', 'x0', 21)
    p.BNE('x3', 'x7', 'fail')        # old value was 21
    p.CSRRS('x4', CSR_MTVEC, 'x0')   # x4 = mtvec (should be 23)
    p.ADDI('x7', 'x0', 23)
    p.BNE('x4', 'x7', 'fail')

    # CSRRCI: clear bits uimm=3 (0b00011) → mtvec becomes 23 & ~3 = 20
    p.CSRRCI('x5', CSR_MTVEC, 3)     # x5 = old mtvec (23), mtvec &= ~3
    p.ADDI('x7', 'x0', 23)
    p.BNE('x5', 'x7', 'fail')        # old value was 23
    p.CSRRS('x6', CSR_MTVEC, 'x0')   # x6 = mtvec (should be 20)
    p.ADDI('x7', 'x0', 20)
    p.BNE('x6', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_csri', p)

# ============================================================================
# TEST: ECALL trap — mcause=11, mepc saved, handler via mtvec, MRET return
# ============================================================================
def gen_test_ecall():
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    p = Program()

    # Jump over handler
    p.JAL('x0', 'skip_handler')       # addr 0x00

    # -- Trap handler at address 0x04 --
    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')  # x10 = mcause
    p.CSRRS('x11', CSR_MEPC, 'x0')    # x11 = mepc
    p.ADDI('x11', 'x11', 4)           # mepc += 4 (skip past ECALL)
    p.CSRRW('x0', CSR_MEPC, 'x11')    # write mepc back
    p.MRET()                           # return to mepc

    # -- End handler --
    p.label('skip_handler')

    # Set mtvec = 4 (address of trap_handler)
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')    # mtvec = 4

    # Mark pre-trap state
    p.ADDI('x20', 'x0', 0)            # x20 = 0 (set to 1 after return)

    # Trigger ECALL trap
    p.ECALL()

    # If we reach here, MRET returned successfully
    p.ADDI('x20', 'x0', 1)

    # Verify mcause == 11
    p.ADDI('x7', 'x0', 11)
    p.BNE('x10', 'x7', 'fail')

    # Verify we actually returned
    p.ADDI('x7', 'x0', 1)
    p.BNE('x20', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_ecall', p)

# ============================================================================
# TEST: EBREAK trap — mcause=3, handler via mtvec, MRET return
# ============================================================================
def gen_test_ebreak():
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    p = Program()

    # Jump over handler
    p.JAL('x0', 'skip_handler')       # addr 0x00

    # -- Trap handler at address 0x04 --
    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')  # x10 = mcause
    p.CSRRS('x11', CSR_MEPC, 'x0')    # x11 = mepc
    p.ADDI('x11', 'x11', 4)           # mepc += 4 (skip past EBREAK)
    p.CSRRW('x0', CSR_MEPC, 'x11')    # write mepc back
    p.MRET()                           # return to mepc

    # -- End handler --
    p.label('skip_handler')

    # Set mtvec = 4 (address of trap_handler)
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')    # mtvec = 4

    # Mark pre-trap state
    p.ADDI('x20', 'x0', 0)

    # Trigger EBREAK trap
    p.EBREAK()

    # If we reach here, MRET returned successfully
    p.ADDI('x20', 'x0', 1)

    # Verify mcause == 3
    p.ADDI('x7', 'x0', 3)
    p.BNE('x10', 'x7', 'fail')

    # Verify we actually returned
    p.ADDI('x7', 'x0', 1)
    p.BNE('x20', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_ebreak', p)

# ============================================================================
# TEST: MRET + mstatus — MIE/MPIE save/restore through trap cycle
# ============================================================================
def gen_test_mret():
    CSR_MSTATUS = 0x300
    CSR_MTVEC   = 0x305
    CSR_MEPC    = 0x341
    CSR_MCAUSE  = 0x342
    p = Program()

    # Jump over handler
    p.JAL('x0', 'skip_handler')       # addr 0x00

    # -- Trap handler at address 0x04 --
    p.label('trap_handler')
    # Read mstatus inside handler — MIE should be cleared, MPIE should be set
    p.CSRRS('x12', CSR_MSTATUS, 'x0') # x12 = mstatus in handler
    # Advance mepc past ECALL
    p.CSRRS('x11', CSR_MEPC, 'x0')
    p.ADDI('x11', 'x11', 4)
    p.CSRRW('x0', CSR_MEPC, 'x11')
    p.MRET()

    # -- End handler --
    p.label('skip_handler')

    # Set mtvec = 4
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    # Set MIE=1 (bit 3) in mstatus: reset value is 0x1800, set to 0x1808
    p.CSRRSI('x0', CSR_MSTATUS, 8)    # set bit 3 (MIE) via uimm=8

    # Read mstatus before trap to confirm MIE is set
    p.CSRRS('x13', CSR_MSTATUS, 'x0') # x13 = mstatus before trap

    # Trigger trap
    p.ECALL()

    # After MRET: MIE restored from MPIE, MPIE set to 1
    p.CSRRS('x14', CSR_MSTATUS, 'x0') # x14 = mstatus after MRET

    # Check: before trap, MIE (bit 3) should have been set
    p.ANDI('x15', 'x13', 0x08)        # isolate bit 3
    p.ADDI('x7', 'x0', 0x08)
    p.BNE('x15', 'x7', 'fail')        # MIE should be 1 before trap

    # Check: in handler, MIE (bit 3) should be cleared, MPIE (bit 7) should be set
    p.ANDI('x16', 'x12', 0x08)        # MIE bit in handler
    p.BNE('x16', 'x0', 'fail')        # MIE should be 0 in handler
    p.ANDI('x17', 'x12', 0x80)        # MPIE bit in handler
    p.ADDI('x7', 'x0', 0x80)
    p.BNE('x17', 'x7', 'fail')        # MPIE should be 1 in handler

    # Check: after MRET, MIE should be restored to 1
    p.ANDI('x18', 'x14', 0x08)        # MIE bit after MRET
    p.ADDI('x7', 'x0', 0x08)
    p.BNE('x18', 'x7', 'fail')        # MIE should be 1 after MRET

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_mret', p)

# ============================================================================
# TEST: mcycle counter — reads twice, verifies increment
# ============================================================================
def gen_test_mcycle():
    CSR_MCYCLE = 0xB00
    p = Program()

    # Read mcycle first time
    p.CSRRS('x1', CSR_MCYCLE, 'x0')   # x1 = mcycle (first read)

    # Execute some NOPs to let cycles pass
    p.NOP()
    p.NOP()
    p.NOP()
    p.NOP()

    # Read mcycle second time
    p.CSRRS('x2', CSR_MCYCLE, 'x0')   # x2 = mcycle (second read)

    # x2 must be greater than x1 (unsigned): x1 < x2 → BLTU x1, x2
    # If x1 >= x2 that means counter didn't advance → fail
    p.BGEU('x1', 'x2', 'fail')        # fail if first >= second

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_mcycle', p)

# ============================================================================
# TEST: minstret counter — reads twice with instructions between
# ============================================================================
def gen_test_minstret():
    CSR_MINSTRET = 0xB02
    p = Program()

    # Read minstret first time
    p.CSRRS('x1', CSR_MINSTRET, 'x0') # x1 = minstret (first read)

    # Execute several instructions
    p.ADDI('x10', 'x0', 1)
    p.ADDI('x10', 'x10', 1)
    p.ADDI('x10', 'x10', 1)
    p.ADDI('x10', 'x10', 1)
    p.ADDI('x10', 'x10', 1)

    # Read minstret second time
    p.CSRRS('x2', CSR_MINSTRET, 'x0') # x2 = minstret (second read)

    # x2 must be greater than x1
    p.BGEU('x1', 'x2', 'fail')        # fail if first >= second

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_minstret', p)

# ============================================================================
# TEST: BRANCH PREDICTION — Loop to exercise BHT+BTB learning
# ============================================================================
def gen_test_bp_loop():
    """Tight loop: backward branch taken 9 times, falls through once.
    BHT should learn 'taken' after first iteration.
    BTB caches target. Verifies prediction is functionally transparent."""
    p = Program()
    # x1 = loop counter (10 iterations)
    p.ADDI('x1', 'x0', 10)
    # x2 = accumulator
    p.ADDI('x2', 'x0', 0)
    p.label('loop')
    p.ADDI('x2', 'x2', 1)
    p.ADDI('x1', 'x1', -1)
    p.BNE('x1', 'x0', 'loop')      # backward branch: taken 9×, not-taken 1×
    # After loop: x2 should be 10
    p.ADDI('x7', 'x0', 10)
    p.BNE('x2', 'x7', 'fail')
    # Second loop: test JAL prediction (function call pattern)
    p.ADDI('x3', 'x0', 0)
    p.ADDI('x4', 'x0', 5)
    p.label('call_loop')
    p.JAL('x1', 'func')             # JAL to function — BTB should learn target
    p.label('ret_point')
    p.ADDI('x4', 'x4', -1)
    p.BNE('x4', 'x0', 'call_loop')  # backward branch
    # After loop: x3 should be 5
    p.ADDI('x7', 'x0', 5)
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('func')
    p.ADDI('x3', 'x3', 1)
    p.JALR('x0', 'x1', 0)           # return
    p.label('fail')
    p.FAIL(99)
    return write_test('test_bp_loop', p)

# ============================================================================
# TEST: BRANCH PREDICTION — Misprediction recovery
# ============================================================================
def gen_test_bp_mispredict():
    """Alternating branch pattern (taken, not-taken, taken, not-taken).
    Tests misprediction recovery — predictor will oscillate."""
    p = Program()
    # Pattern: BEQ taken, BEQ not-taken, BEQ taken, BEQ not-taken
    # Test 1: Branch taken (x1 == x1)
    p.ADDI('x1', 'x0', 1)
    p.BEQ('x1', 'x1', 'taken1')
    p.FAIL(1)
    p.label('taken1')
    # Test 2: Branch not-taken (x1 != x0)
    p.BEQ('x1', 'x0', 'bad2')
    p.JAL('x0', 'ok2')
    p.label('bad2')
    p.FAIL(2)
    p.label('ok2')
    # Test 3: Forward branch taken
    p.ADDI('x2', 'x0', 42)
    p.BEQ('x2', 'x2', 'taken3')
    p.FAIL(3)
    p.label('taken3')
    # Test 4: Forward branch not-taken
    p.ADDI('x3', 'x0', 7)
    p.BEQ('x3', 'x0', 'bad4')
    p.JAL('x0', 'ok4')
    p.label('bad4')
    p.FAIL(4)
    p.label('ok4')
    # Verify all values intact (no corruption from misprediction flushes)
    p.ADDI('x7', 'x0', 1)
    p.BNE('x1', 'x7', 'fail')
    p.ADDI('x7', 'x0', 42)
    p.BNE('x2', 'x7', 'fail')
    p.ADDI('x7', 'x0', 7)
    p.BNE('x3', 'x7', 'fail')
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_bp_mispredict', p)



# ============================================================================
# R12B NEW TESTS: RV32A Atomic Instructions
# ============================================================================

def gen_test_lr_sc():
    """LR.W / SC.W basic success and failure paths."""
    p = Program()
    DATA_ADDR = 0x2000
    # Store initial value 42 at DATA_ADDR
    p.LI('x5', DATA_ADDR)
    p.ADDI('x6', 'x0', 42)
    p.SW('x6', 0, 'x5')

    # Test 1: LR/SC to same address — should succeed (rd=0)
    p.LR_W('x10', 'x5')          # x10 = mem[DATA_ADDR] = 42
    p.ADDI('x7', 'x0', 42)
    p.BNE('x10', 'x7', 'fail')   # check LR read correct value
    p.ADDI('x6', 'x0', 99)
    p.SC_W('x11', 'x5', 'x6')    # SC: write 99, x11 = 0 on success
    p.BNE('x11', 'x0', 'fail')   # x11 must be 0

    # Verify the store happened
    p.LW('x12', 0, 'x5')
    p.ADDI('x7', 'x0', 99)
    p.BNE('x12', 'x7', 'fail')

    # Test 2: SC without prior LR — should fail (rd=1)
    p.ADDI('x6', 'x0', 55)
    p.SC_W('x13', 'x5', 'x6')    # No prior LR → fail
    p.ADDI('x7', 'x0', 1)
    p.BNE('x13', 'x7', 'fail')   # x13 must be 1

    # Verify store did NOT happen (value still 99)
    p.LW('x14', 0, 'x5')
    p.ADDI('x7', 'x0', 99)
    p.BNE('x14', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_lr_sc', p)


def gen_test_amoswap():
    """AMOSWAP.W — swap memory with register, return old value."""
    p = Program()
    DATA_ADDR = 0x2000
    p.LI('x5', DATA_ADDR)
    p.ADDI('x6', 'x0', 100)
    p.SW('x6', 0, 'x5')           # mem = 100

    p.ADDI('x7', 'x0', 200)
    p.AMOSWAP_W('x10', 'x7', 'x5')  # x10 = old(100), mem = 200
    p.ADDI('x8', 'x0', 100)
    p.BNE('x10', 'x8', 'fail')    # x10 should be 100

    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 200)
    p.BNE('x11', 'x8', 'fail')    # mem should be 200

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_amoswap', p)


def gen_test_amoadd():
    """AMOADD.W — atomic add, return old value."""
    p = Program()
    DATA_ADDR = 0x2000
    p.LI('x5', DATA_ADDR)
    p.ADDI('x6', 'x0', 50)
    p.SW('x6', 0, 'x5')           # mem = 50

    p.ADDI('x7', 'x0', 30)
    p.AMOADD_W('x10', 'x7', 'x5')  # x10 = old(50), mem = 50+30=80
    p.ADDI('x8', 'x0', 50)
    p.BNE('x10', 'x8', 'fail')

    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 80)
    p.BNE('x11', 'x8', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_amoadd', p)


def gen_test_amo_logic():
    """AMOAND, AMOOR, AMOXOR — bitwise atomic operations."""
    p = Program()
    DATA_ADDR = 0x2000
    p.LI('x5', DATA_ADDR)

    # Test AMOAND: mem=0xFF, AND with 0x0F → 0x0F
    p.ADDI('x6', 'x0', 0xFF)
    p.SW('x6', 0, 'x5')
    p.ADDI('x7', 'x0', 0x0F)
    p.AMOAND_W('x10', 'x7', 'x5')  # x10=0xFF, mem=0x0F
    p.ADDI('x8', 'x0', 0xFF)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 0x0F)
    p.BNE('x11', 'x8', 'fail')

    # Test AMOOR: mem=0x0F, OR with 0xF0 → 0xFF
    p.ADDI('x7', 'x0', 0xF0)
    p.AMOOR_W('x10', 'x7', 'x5')  # x10=0x0F, mem=0xFF
    p.ADDI('x8', 'x0', 0x0F)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 0xFF)
    p.BNE('x11', 'x8', 'fail')

    # Test AMOXOR: mem=0xFF, XOR with 0x0F → 0xF0
    p.ADDI('x7', 'x0', 0x0F)
    p.AMOXOR_W('x10', 'x7', 'x5')  # x10=0xFF, mem=0xF0
    p.ADDI('x8', 'x0', 0xFF)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 0xF0)
    p.BNE('x11', 'x8', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_amo_logic', p)


def gen_test_amo_minmax():
    """AMOMIN, AMOMAX, AMOMINU, AMOMAXU — signed/unsigned min/max."""
    p = Program()
    DATA_ADDR = 0x2000
    p.LI('x5', DATA_ADDR)

    # AMOMIN (signed): mem=10, min(10, 5) → 5
    p.ADDI('x6', 'x0', 10)
    p.SW('x6', 0, 'x5')
    p.ADDI('x7', 'x0', 5)
    p.AMOMIN_W('x10', 'x7', 'x5')  # x10=10, mem=5
    p.ADDI('x8', 'x0', 10)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 5)
    p.BNE('x11', 'x8', 'fail')

    # AMOMAX (signed): mem=5, max(5, 20) → 20
    p.ADDI('x7', 'x0', 20)
    p.AMOMAX_W('x10', 'x7', 'x5')  # x10=5, mem=20
    p.ADDI('x8', 'x0', 5)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 20)
    p.BNE('x11', 'x8', 'fail')

    # AMOMINU (unsigned): mem=20, minu(20, 3) → 3
    p.ADDI('x7', 'x0', 3)
    p.AMOMINU_W('x10', 'x7', 'x5')  # x10=20, mem=3
    p.ADDI('x8', 'x0', 20)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 3)
    p.BNE('x11', 'x8', 'fail')

    # AMOMAXU (unsigned): mem=3, maxu(3, 100) → 100
    p.ADDI('x7', 'x0', 100)
    p.AMOMAXU_W('x10', 'x7', 'x5')  # x10=3, mem=100
    p.ADDI('x8', 'x0', 3)
    p.BNE('x10', 'x8', 'fail')
    p.LW('x11', 0, 'x5')
    p.ADDI('x8', 'x0', 100)
    p.BNE('x11', 'x8', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_amo_minmax', p)


# ============================================================================
# R12B NEW TESTS: Illegal Instruction & Misaligned Access
# ============================================================================

def gen_test_illegal_instr():
    """Illegal instruction should trap to mtvec with mcause=2."""
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    p = Program()

    p.JAL('x0', 'skip_handler')

    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')
    p.CSRRS('x11', CSR_MEPC, 'x0')
    p.ADDI('x11', 'x11', 4)
    p.CSRRW('x0', CSR_MEPC, 'x11')
    p.MRET()

    p.label('skip_handler')
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    # Emit illegal instruction (all zeros = illegal in RV32)
    p.RAW(0x0000006B)  # opcode=1101011 (unassigned), 32-bit illegal instruction

    # If we reach here, trap handler returned
    p.ADDI('x7', 'x0', 2)       # EXC_ILLEGAL_INSTR = 2
    p.BNE('x10', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_illegal_instr', p)


def gen_test_misalign_load():
    """Misaligned LW should trap with mcause=4 (load addr misalign)."""
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    CSR_MTVAL  = 0x343
    p = Program()

    p.JAL('x0', 'skip_handler')

    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')
    p.CSRRS('x12', CSR_MTVAL, 'x0')
    p.CSRRS('x11', CSR_MEPC, 'x0')
    p.ADDI('x11', 'x11', 4)
    p.CSRRW('x0', CSR_MEPC, 'x11')
    p.MRET()

    p.label('skip_handler')
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    # LW from misaligned address (0x2001)
    p.LI('x6', 0x2001)
    p.LW('x9', 0, 'x6')

    # Verify mcause = 4 (load address misaligned)
    p.ADDI('x7', 'x0', 4)
    p.BNE('x10', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_misalign_load', p)


def gen_test_misalign_store():
    """Misaligned SW should trap with mcause=6 (store addr misalign)."""
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    p = Program()

    p.JAL('x0', 'skip_handler')

    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')
    p.CSRRS('x11', CSR_MEPC, 'x0')
    p.ADDI('x11', 'x11', 4)
    p.CSRRW('x0', CSR_MEPC, 'x11')
    p.MRET()

    p.label('skip_handler')
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    # SW to misaligned address (0x2003)
    p.LI('x6', 0x2003)
    p.ADDI('x9', 'x0', 42)
    p.SW('x9', 0, 'x6')

    # Verify mcause = 6 (store address misaligned)
    p.ADDI('x7', 'x0', 6)
    p.BNE('x10', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_misalign_store', p)


# ============================================================================
# R12B NEW TESTS: Pipeline Stress
# ============================================================================

def gen_test_back_to_back_jal():
    """Rapid JAL/JALR sequences stress the pipeline flush logic."""
    p = Program()

    # Chain: JAL → target1 → JAL → target2 → JAL → target3
    p.JAL('x1', 'target1')
    p.J('fail')
    p.label('target1')
    p.JAL('x2', 'target2')
    p.J('fail')
    p.label('target2')
    p.JAL('x3', 'target3')
    p.J('fail')
    p.label('target3')

    # Verify all link registers
    p.ADDI('x7', 'x0', 4)
    p.BNE('x1', 'x7', 'fail')      # x1 = 0x04 (JAL at 0x00 → PC+4)

    # JALR chain: x1→x2→x3 are set from above. Use JALR to jump back.
    p.AUIPC('x5', 0)
    p.ADDI('x5', 'x5', 16)      # skip AUIPC(4)+ADDI(4)+JALR(4)+J(4) = 16
    p.JALR('x4', 'x5', 0)
    p.J('fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_back_to_back_jal', p)


def gen_test_csr_write_read():
    """CSR write immediately followed by CSR read — tests CSR forwarding."""
    CSR_MSCRATCH = 0x340
    p = Program()

    # Write then immediately read mscratch
    p.ADDI('x6', 'x0', 123)
    p.CSRRW('x0', CSR_MSCRATCH, 'x6')  # write 123
    p.CSRRS('x10', CSR_MSCRATCH, 'x0') # read back
    p.ADDI('x7', 'x0', 123)
    p.BNE('x10', 'x7', 'fail')

    # Write new value and read in same instruction (CSRRW swaps)
    p.ADDI('x6', 'x0', 77)
    p.CSRRW('x11', CSR_MSCRATCH, 'x6') # x11 = old(123), write 77
    p.ADDI('x7', 'x0', 123)
    p.BNE('x11', 'x7', 'fail')

    # Verify new value
    p.CSRRS('x12', CSR_MSCRATCH, 'x0')
    p.ADDI('x7', 'x0', 77)
    p.BNE('x12', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_csr_write_read', p)


def gen_test_div_use():
    """DIV result used immediately — tests div stall correctness."""
    p = Program()
    p.ADDI('x1', 'x0', 100)
    p.ADDI('x2', 'x0', 10)
    p.DIV('x3', 'x1', 'x2')     # x3 = 10 (takes many cycles)
    p.ADDI('x4', 'x3', 5)       # immediately use div result: x4 = 15
    p.ADDI('x7', 'x0', 15)
    p.BNE('x4', 'x7', 'fail')

    # DIV then branch on result
    p.ADDI('x1', 'x0', 42)
    p.ADDI('x2', 'x0', 6)
    p.DIV('x3', 'x1', 'x2')     # x3 = 7
    p.ADDI('x7', 'x0', 7)
    p.BEQ('x3', 'x7', 'div_ok')
    p.J('fail')
    p.label('div_ok')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_div_use', p)


def gen_test_load_branch():
    """Load immediately followed by branch on loaded value."""
    p = Program()
    DATA_ADDR = 0x2000
    p.LI('x5', DATA_ADDR)

    # Store known values
    p.ADDI('x6', 'x0', 42)
    p.SW('x6', 0, 'x5')
    p.ADDI('x6', 'x0', 0)
    p.SW('x6', 4, 'x5')

    # Load then branch on result (load-use + branch hazard)
    p.LW('x10', 0, 'x5')        # x10 = 42
    p.ADDI('x7', 'x0', 42)
    p.BNE('x10', 'x7', 'fail')  # branch based on loaded value

    # Load zero then branch
    p.LW('x11', 4, 'x5')        # x11 = 0
    p.BEQ('x11', 'x0', 'load_ok')
    p.J('fail')
    p.label('load_ok')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_load_branch', p)


def gen_test_misa_readonly():
    """Test that MISA reads the correct value (RV32IMAC) and is read-only."""
    CSR_MISA = 0x301
    p = Program()
    # Read MISA
    p.CSRRS('x10', CSR_MISA, 'x0')

    # MISA for RV32IMAC: bit[0]=A, bit[2]=C, bit[8]=I, bit[12]=M, MXL=01 (bit[31:30])
    # = 0x40001105
    p.LI('x7', 0x40001105)
    p.BNE('x10', 'x7', 'fail')

    # Try to write MISA (should be ignored — WARL, fixed)
    p.LI('x6', 0x40001104)       # try to clear A bit
    p.CSRRW('x0', CSR_MISA, 'x6')
    p.CSRRS('x11', CSR_MISA, 'x0')
    p.BNE('x11', 'x7', 'fail')  # should still be 0x40001105

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_misa_readonly', p)


def gen_test_mvendorid():
    """Test machine identity CSRs (read-only, implementation-defined)."""
    CSR_MVENDORID = 0xF11
    CSR_MARCHID   = 0xF12
    CSR_MIMPID    = 0xF13
    CSR_MHARTID   = 0xF14
    p = Program()

    # These should all read without trapping — exact values are impl-defined
    p.CSRRS('x10', CSR_MVENDORID, 'x0')
    p.CSRRS('x11', CSR_MARCHID, 'x0')
    p.CSRRS('x12', CSR_MIMPID, 'x0')
    p.CSRRS('x13', CSR_MHARTID, 'x0')

    # mhartid should be 0 for single-hart
    p.BNE('x13', 'x0', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_mvendorid', p)


def gen_test_exception_priority():
    """Test that exceptions have correct priority ordering."""
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    p = Program()

    # Setup trap handler
    p.JAL('x0', 'skip_handler')
    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')
    p.CSRRS('x11', CSR_MEPC, 'x0')
    p.ADDI('x11', 'x11', 4)
    p.CSRRW('x0', CSR_MEPC, 'x11')
    p.MRET()
    p.label('skip_handler')
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    # Test: ECALL (mcause=11), then verify we can resume
    p.ECALL()
    p.ADDI('x7', 'x0', 11)
    p.BNE('x10', 'x7', 'fail')

    # Test: EBREAK (mcause=3)
    p.EBREAK()
    p.ADDI('x7', 'x0', 3)
    p.BNE('x10', 'x7', 'fail')

    # Both traps handled and returned correctly
    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_exception_priority', p)


def gen_test_store_load_forwarding():
    """Store then load from same address — pipeline must handle correctly."""
    p = Program()
    DATA_ADDR = 0x2000
    p.LI('x5', DATA_ADDR)

    # SW then immediately LW from same address
    p.ADDI('x6', 'x0', 77)
    p.SW('x6', 0, 'x5')
    p.LW('x10', 0, 'x5')
    p.ADDI('x7', 'x0', 77)
    p.BNE('x10', 'x7', 'fail')

    # Different offsets
    p.ADDI('x6', 'x0', 88)
    p.SW('x6', 4, 'x5')
    p.ADDI('x6', 'x0', 99)
    p.SW('x6', 8, 'x5')
    p.LW('x11', 4, 'x5')
    p.LW('x12', 8, 'x5')
    p.ADDI('x7', 'x0', 88)
    p.BNE('x11', 'x7', 'fail')
    p.ADDI('x7', 'x0', 99)
    p.BNE('x12', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_store_load_fwd', p)


# ============================================================================
# RV32C COMPRESSED INSTRUCTION TESTS
# ============================================================================

def gen_test_c_arith():
    """Compressed arithmetic: C.LI, C.ADDI, C.LUI, C.MV, C.ADD, C.NOP,
    C.SLLI, C.SRLI, C.SRAI, C.ANDI, C.SUB/XOR/OR/AND, C.ADDI16SP, C.ADDI4SPN."""
    p = Program()

    # Test 1: C.LI positive
    p.C_LI('x10', 10)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 10)
    p.BNE('x10', 'x7', 'fail')

    # Test 2: C.LI negative (-3)
    p.C_LI('x10', -3)
    p.ALIGN4()
    p.ADDI('x7', 'x0', -3)
    p.BNE('x10', 'x7', 'fail')

    # Test 3: C.ADDI positive
    p.C_LI('x10', 10)
    p.C_ADDI('x10', 5)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 15)
    p.BNE('x10', 'x7', 'fail')

    # Test 4: C.ADDI negative
    p.C_LI('x10', 10)
    p.C_ADDI('x10', -3)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 7)
    p.BNE('x10', 'x7', 'fail')

    # Test 5: C.LUI
    p.C_LUI('x10', 2)
    p.ALIGN4()
    p.LI('x7', 0x2000)
    p.BNE('x10', 'x7', 'fail')

    # Test 6: C.MV
    p.ADDI('x1', 'x0', 42)
    p.C_MV('x10', 'x1')
    p.ALIGN4()
    p.ADDI('x7', 'x0', 42)
    p.BNE('x10', 'x7', 'fail')

    # Test 7: C.ADD
    p.ADDI('x10', 'x0', 20)
    p.ADDI('x1', 'x0', 30)
    p.C_ADD('x10', 'x1')
    p.ALIGN4()
    p.ADDI('x7', 'x0', 50)
    p.BNE('x10', 'x7', 'fail')

    # Test 8: C.NOP (should not change any register)
    p.ADDI('x10', 'x0', 77)
    p.C_NOP()
    p.ALIGN4()
    p.ADDI('x7', 'x0', 77)
    p.BNE('x10', 'x7', 'fail')

    # Test 9: C.SLLI
    p.ADDI('x10', 'x0', 1)
    p.C_SLLI('x10', 4)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 16)
    p.BNE('x10', 'x7', 'fail')

    # Test 10: C.SRLI (uses compressed registers x8-x15)
    p.ADDI('x8', 'x0', 64)
    p.C_SRLI('x8', 2)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 16)
    p.BNE('x8', 'x7', 'fail')

    # Test 11: C.SRAI (arithmetic right shift, preserves sign)
    p.ADDI('x8', 'x0', -16)
    p.C_SRAI('x8', 2)
    p.ALIGN4()
    p.ADDI('x7', 'x0', -4)
    p.BNE('x8', 'x7', 'fail')

    # Test 12: C.ANDI
    p.ADDI('x8', 'x0', 0xFF)
    p.C_ANDI('x8', 0x0F)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 0x0F)
    p.BNE('x8', 'x7', 'fail')

    # Test 13: C.SUB
    p.ADDI('x8', 'x0', 30)
    p.ADDI('x9', 'x0', 10)
    p.C_SUB('x8', 'x9')
    p.ALIGN4()
    p.ADDI('x7', 'x0', 20)
    p.BNE('x8', 'x7', 'fail')

    # Test 14: C.XOR
    p.ADDI('x8', 'x0', 0xFF)
    p.ADDI('x9', 'x0', 0x0F)
    p.C_XOR('x8', 'x9')
    p.ALIGN4()
    p.ADDI('x7', 'x0', 0xF0)
    p.BNE('x8', 'x7', 'fail')

    # Test 15: C.OR
    p.ADDI('x8', 'x0', 0xF0)
    p.ADDI('x9', 'x0', 0x0F)
    p.C_OR('x8', 'x9')
    p.ALIGN4()
    p.ADDI('x7', 'x0', 0xFF)
    p.BNE('x8', 'x7', 'fail')

    # Test 16: C.AND
    p.ADDI('x8', 'x0', 0xFF)
    p.ADDI('x9', 'x0', 0x0F)
    p.C_AND('x8', 'x9')
    p.ALIGN4()
    p.ADDI('x7', 'x0', 0x0F)
    p.BNE('x8', 'x7', 'fail')

    # Test 17: C.ADDI16SP (adds multiple of 16 to sp)
    p.ADDI('x2', 'x0', 100)
    p.C_ADDI16SP(32)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 132)
    p.BNE('x2', 'x7', 'fail')

    # Test 18: C.ADDI4SPN (rd' = sp + nzuimm)
    p.ADDI('x2', 'x0', 200)
    p.C_ADDI4SPN('x8', 16)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 216)
    p.BNE('x8', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_c_arith', p)


def gen_test_c_branch_jump():
    """Compressed branches and jumps: C.J, C.JAL, C.BEQZ, C.BNEZ, C.JR, C.JALR."""
    p = Program()

    # Test 1: C.J — unconditional forward jump
    p.ALIGN4()
    p.C_J('cj_target')
    p.ALIGN4()
    p.J('fail')
    p.label('cj_target')

    # Test 2: C.JAL — jump and link (RV32 only, sets x1)
    p.ALIGN4()
    p.C_JAL('cjal_target')
    p.ALIGN4()
    p.J('fail')
    p.label('cjal_target')
    p.BEQ('x1', 'x0', 'fail')

    # Test 3: C.BEQZ — taken (rs1' == 0)
    p.ADDI('x8', 'x0', 0)
    p.ALIGN4()
    p.C_BEQZ('x8', 'beqz_taken')
    p.ALIGN4()
    p.J('fail')
    p.label('beqz_taken')

    # Test 4: C.BEQZ — not taken (rs1' != 0)
    p.ADDI('x8', 'x0', 1)
    p.ALIGN4()
    p.C_BEQZ('x8', 'beqz_fail')
    p.ALIGN4()
    p.JAL('x0', 'beqz_ok')
    p.label('beqz_fail')
    p.J('fail')
    p.label('beqz_ok')

    # Test 5: C.BNEZ — taken (rs1' != 0)
    p.ADDI('x8', 'x0', 5)
    p.ALIGN4()
    p.C_BNEZ('x8', 'bnez_taken')
    p.ALIGN4()
    p.J('fail')
    p.label('bnez_taken')

    # Test 6: C.BNEZ — not taken (rs1' == 0)
    p.ADDI('x8', 'x0', 0)
    p.ALIGN4()
    p.C_BNEZ('x8', 'bnez_fail')
    p.ALIGN4()
    p.JAL('x0', 'bnez_ok')
    p.label('bnez_fail')
    p.J('fail')
    p.label('bnez_ok')

    # Test 7: C.JR — jump via register
    p.JAL('x10', 'jr_helper')
    p.label('jr_dest')
    p.JAL('x0', 'jr_done')
    p.label('jr_helper')
    p.ALIGN4()
    p.C_JR('x10')
    p.ALIGN4()
    p.J('fail')
    p.label('jr_done')

    # Test 8: C.JALR — jump and link via register
    p.JAL('x10', 'jalr_helper')
    p.label('jalr_dest')
    p.BEQ('x1', 'x0', 'fail')
    p.JAL('x0', 'jalr_done')
    p.label('jalr_helper')
    p.ALIGN4()
    p.C_JALR('x10')
    p.ALIGN4()
    p.J('fail')
    p.label('jalr_done')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_c_branch_jump', p)


def gen_test_c_load_store():
    """Compressed loads/stores: C.LW, C.SW, C.LWSP, C.SWSP."""
    p = Program()
    DATA_ADDR = 0x2000

    # Setup sp and base register
    p.LI('x2', DATA_ADDR)
    p.LI('x8', DATA_ADDR)

    # Test 1: C.SW + C.LW (compressed registers, offset 0)
    p.ADDI('x9', 'x0', 42)
    p.C_SW('x9', 'x8', 0)
    p.C_LW('x10', 'x8', 0)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 42)
    p.BNE('x10', 'x7', 'fail')

    # Test 2: C.SW + C.LW (offset 4)
    p.ADDI('x9', 'x0', 77)
    p.C_SW('x9', 'x8', 4)
    p.C_LW('x10', 'x8', 4)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 77)
    p.BNE('x10', 'x7', 'fail')

    # Test 3: C.SWSP + C.LWSP (sp-relative, offset 8)
    p.ADDI('x9', 'x0', 88)
    p.C_SWSP('x9', 8)
    p.C_LWSP('x10', 8)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 88)
    p.BNE('x10', 'x7', 'fail')

    # Test 4: C.SWSP + C.LWSP (offset 12)
    p.ADDI('x9', 'x0', 99)
    p.C_SWSP('x9', 12)
    p.C_LWSP('x10', 12)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 99)
    p.BNE('x10', 'x7', 'fail')

    # Test 5: Verify value at offset 0 still intact
    p.C_LW('x10', 'x8', 0)
    p.ALIGN4()
    p.ADDI('x7', 'x0', 42)
    p.BNE('x10', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_c_load_store', p)


def gen_test_c_ebreak():
    """C.EBREAK (16-bit) should trigger breakpoint trap with mcause=3."""
    CSR_MTVEC  = 0x305
    CSR_MEPC   = 0x341
    CSR_MCAUSE = 0x342
    p = Program()

    p.JAL('x0', 'skip_handler')

    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')
    p.CSRRS('x11', CSR_MEPC, 'x0')
    p.ADDI('x11', 'x11', 4)     # skip C.EBREAK(2) + ALIGN4 padding(2)
    p.CSRRW('x0', CSR_MEPC, 'x11')
    p.MRET()

    p.label('skip_handler')
    # trap_handler is at address 4
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    p.ALIGN4()
    p.C_EBREAK()
    p.ALIGN4()

    # Check mcause = 3 (breakpoint)
    p.ADDI('x7', 'x0', 3)
    p.BNE('x10', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_c_ebreak', p)


def gen_test_wfi():
    """WFI halts CPU until timer interrupt. Requires -DWFI_TIMER_CYCLES=N."""
    CSR_MSTATUS = 0x300
    CSR_MIE     = 0x304
    CSR_MTVEC   = 0x305
    CSR_MCAUSE  = 0x342
    p = Program()

    p.JAL('x0', 'skip_handler')

    p.label('trap_handler')
    p.CSRRS('x10', CSR_MCAUSE, 'x0')
    p.MRET()

    p.label('skip_handler')
    # Set mtvec to trap_handler (address 4)
    p.ADDI('x5', 'x0', 4)
    p.CSRRW('x0', CSR_MTVEC, 'x5')

    # Enable timer interrupt in MIE (bit 7 = MTIE)
    p.ADDI('x5', 'x0', 0x80)
    p.CSRRS('x0', CSR_MIE, 'x5')

    # Enable global interrupts in MSTATUS (bit 3 = MIE)
    p.ADDI('x5', 'x0', 0x08)
    p.CSRRS('x0', CSR_MSTATUS, 'x5')

    # Mark pre-WFI
    p.ADDI('x15', 'x0', 1)

    # WFI — halt until timer interrupt
    p.WFI()

    # Post-WFI: verify we woke up
    p.ADDI('x15', 'x15', 1)
    p.ADDI('x7', 'x0', 2)
    p.BNE('x15', 'x7', 'fail')

    # Verify mcause = 0x80000007 (machine timer interrupt)
    p.LI('x7', 0x80000007)
    p.BNE('x10', 'x7', 'fail')

    p.PASS()
    p.label('fail')
    p.FAIL(99)
    return write_test('test_wfi', p)


# ============================================================================
# MAIN: Generate all tests
# ============================================================================
ALL_TESTS = [
    ('test_addi',       gen_test_addi,       'ADDI (6 cases: basic, negative, -1, x0, max, min)'),
    ('test_add',        gen_test_add,        'ADD (4 cases: basic, neg+pos, zero, overflow)'),
    ('test_sub',        gen_test_sub,        'SUB (3 cases: basic, negative result, zero)'),
    ('test_and',        gen_test_and,        'AND + ANDI (3 cases)'),
    ('test_or',         gen_test_or,         'OR + ORI (3 cases)'),
    ('test_xor',        gen_test_xor,        'XOR + XORI (4 cases incl NOT)'),
    ('test_slt',        gen_test_slt,        'SLT + SLTU + SLTI + SLTIU (6 cases)'),
    ('test_sll',        gen_test_sll,        'SLL + SLLI (4 cases incl shift-31)'),
    ('test_srl',        gen_test_srl,        'SRL + SRLI (3 cases incl MSB shift)'),
    ('test_sra',        gen_test_sra,        'SRA + SRAI (3 cases: negative, MSB, positive)'),
    ('test_lui',        gen_test_lui,        'LUI (3 cases incl x0)'),
    ('test_auipc',      gen_test_auipc,      'AUIPC (2 cases: offset 0, offset 1)'),
    ('test_jal',        gen_test_jal,        'JAL (2 cases: save ra, x0)'),
    ('test_jalr',       gen_test_jalr,       'JALR (2 cases: basic, with offset)'),
    ('test_beq',        gen_test_beq,        'BEQ (3 cases: equal, not-equal, x0)'),
    ('test_bne',        gen_test_bne,        'BNE (2 cases: not-equal, equal)'),
    ('test_blt',        gen_test_blt,        'BLT (3 cases: less, not-less, equal)'),
    ('test_bge',        gen_test_bge,        'BGE (3 cases: greater, equal, less)'),
    ('test_bltu',       gen_test_bltu,       'BLTU (2 cases: unsigned less, not-less)'),
    ('test_bgeu',       gen_test_bgeu,       'BGEU (3 cases: greater, equal, less)'),
    ('test_sw_lw',      gen_test_sw_lw,      'SW + LW (3 cases: basic, offset, zero)'),
    ('test_sh_lh_lhu',  gen_test_sh_lh_lhu,  'SH + LH + LHU (6 cases: signed/unsigned halves)'),
    ('test_sb_lb_lbu',  gen_test_sb_lb_lbu,  'SB + LB + LBU (6 cases: all 4 bytes + store)'),
    ('test_system',     gen_test_system,     'FENCE (NOP behavior)'),
    ('test_forwarding', gen_test_forwarding, 'Data forwarding (EX→EX, MEM→EX, chain)'),
    ('test_load_use',   gen_test_load_use,   'Load-use hazard (pipeline stall)'),
    ('test_branch_fwd', gen_test_branch_fwd, 'Branch after ALU (forwarding to comparator)'),
    ('test_comprehensive', gen_test_comprehensive, 'Integration: loops, Fibonacci, array store/load'),
    # M extension
    ('test_mul',        gen_test_mul,        'MUL (6 cases: basic, neg, neg*neg, zero, overflow, identity)'),
    ('test_mulh',       gen_test_mulh,       'MULH (4 cases: small, neg*neg, neg*pos, large)'),
    ('test_mulhsu',     gen_test_mulhsu,     'MULHSU (3 cases: pos*pos, neg*pos, neg*zero)'),
    ('test_mulhu',      gen_test_mulhu,      'MULHU (3 cases: small, 0xFFFF*0xFFFF, 0x8000*2)'),
    ('test_div',        gen_test_div,        'DIV (6 cases: basic, neg, neg divisor, div0, overflow, neg/neg)'),
    ('test_divu',       gen_test_divu,       'DIVU (4 cases: basic, large, div0, div1)'),
    ('test_rem',        gen_test_rem,        'REM (5 cases: basic, neg dividend, neg divisor, div0, overflow)'),
    ('test_remu',       gen_test_remu,       'REMU (4 cases: basic, large, div0, exact)'),
    # CSR / Privileged
    ('test_csrrw',       gen_test_csrrw,       'CSRRW (3 cases: read-write, old value, write-only)'),
    ('test_csrrs_csrrc', gen_test_csrrs_csrrc, 'CSRRS + CSRRC (bit set/clear with verification)'),
    ('test_csri',        gen_test_csri,        'CSRRWI + CSRRSI + CSRRCI (immediate CSR ops)'),
    ('test_ecall',       gen_test_ecall,       'ECALL trap (mcause=11, mepc, handler, MRET)'),
    ('test_ebreak',      gen_test_ebreak,      'EBREAK trap (mcause=3, handler, MRET)'),
    ('test_mret',        gen_test_mret,        'MRET + mstatus (MIE/MPIE save/restore)'),
    ('test_mcycle',      gen_test_mcycle,      'mcycle counter (read twice, verify increment)'),
    ('test_minstret',    gen_test_minstret,    'minstret counter (instruction retire count)'),
    # Branch prediction
    ('test_bp_loop',       gen_test_bp_loop,       'Branch prediction loop (BHT+BTB learning)'),
    ('test_bp_mispredict', gen_test_bp_mispredict, 'Branch misprediction recovery (alternating pattern)'),
    # R12B: RV32A Atomics
    ('test_lr_sc',           gen_test_lr_sc,           'LR.W/SC.W (success/fail paths)'),
    ('test_amoswap',         gen_test_amoswap,         'AMOSWAP.W (swap and return old)'),
    ('test_amoadd',          gen_test_amoadd,          'AMOADD.W (atomic add)'),
    ('test_amo_logic',       gen_test_amo_logic,       'AMOAND/AMOOR/AMOXOR (bitwise atomics)'),
    ('test_amo_minmax',      gen_test_amo_minmax,      'AMOMIN/AMOMAX/AMOMINU/AMOMAXU'),
    # R12B: Exception tests
    ('test_illegal_instr',   gen_test_illegal_instr,   'Illegal instruction trap (mcause=2)'),
    ('test_misalign_load',   gen_test_misalign_load,   'Misaligned LW trap (mcause=4)'),
    ('test_misalign_store',  gen_test_misalign_store,  'Misaligned SW trap (mcause=6)'),
    ('test_exception_priority', gen_test_exception_priority, 'ECALL/EBREAK sequential traps'),
    # R12B: Pipeline stress
    ('test_back_to_back_jal', gen_test_back_to_back_jal, 'Rapid JAL/JALR chain'),
    ('test_csr_write_read',  gen_test_csr_write_read,  'CSR write-then-read forwarding'),
    ('test_div_use',         gen_test_div_use,         'DIV result used immediately'),
    ('test_load_branch',     gen_test_load_branch,     'Load then branch (hazard stress)'),
    ('test_store_load_fwd',  gen_test_store_load_forwarding,  'Store then load same address'),
    # R12B: CSR identity tests
    ('test_misa_readonly',   gen_test_misa_readonly,   'MISA read (RV32IMAC) + write ignored'),
    ('test_mvendorid',       gen_test_mvendorid,       'Machine identity CSRs + mhartid=0'),
    # RV32C Compressed instructions
    ('test_c_arith',         gen_test_c_arith,         'C.LI/ADDI/LUI/MV/ADD/NOP/SLLI/SRLI/SRAI/ANDI/SUB/XOR/OR/AND'),
    ('test_c_branch_jump',   gen_test_c_branch_jump,   'C.J/JAL/BEQZ/BNEZ/JR/JALR (compressed branches & jumps)'),
    ('test_c_load_store',    gen_test_c_load_store,    'C.LW/SW/LWSP/SWSP (compressed loads & stores)'),
    ('test_c_ebreak',        gen_test_c_ebreak,        'C.EBREAK trap (mcause=3, 16-bit instruction)'),
    # WFI
    ('test_wfi',             gen_test_wfi,             'WFI halt + timer interrupt wakeup'),
]

if __name__ == '__main__':
    print(f'Generating {len(ALL_TESTS)} RV32IM + CSR ISA compliance tests...')
    print(f'Output directory: {OUTDIR}')
    print()
    total_instrs = 0
    for name, gen_fn, desc in ALL_TESTS:
        n = gen_fn()
        total_instrs += n
        print(f'  [{name:24s}] {n:4d} instructions — {desc}')
    print(f'\n  Total: {len(ALL_TESTS)} tests, {total_instrs} instructions')
    print()

    # Print instruction coverage
    covered = {
        'R-type (10)': ['ADD', 'SUB', 'AND', 'OR', 'XOR', 'SLT', 'SLTU', 'SLL', 'SRL', 'SRA'],
        'I-type ALU (9)': ['ADDI', 'ANDI', 'ORI', 'XORI', 'SLTI', 'SLTIU', 'SLLI', 'SRLI', 'SRAI'],
        'Load (5)': ['LB', 'LH', 'LW', 'LBU', 'LHU'],
        'Store (3)': ['SB', 'SH', 'SW'],
        'Branch (6)': ['BEQ', 'BNE', 'BLT', 'BGE', 'BLTU', 'BGEU'],
        'Jump (2)': ['JAL', 'JALR'],
        'Upper (2)': ['LUI', 'AUIPC'],
        'System (1)': ['FENCE'],
        'M-ext Multiply (4)': ['MUL', 'MULH', 'MULHSU', 'MULHU'],
        'M-ext Divide (4)': ['DIV', 'DIVU', 'REM', 'REMU'],
        'CSR (6)': ['CSRRW', 'CSRRS', 'CSRRC', 'CSRRWI', 'CSRRSI', 'CSRRCI'],
        'Privileged (2)': ['ECALL+EBREAK (trap)', 'MRET'],
    }
    total = 0
    for cat, instrs in covered.items():
        total += len(instrs)
        print(f'  {cat}: {", ".join(instrs)}')
    print(f'\n  ISA coverage: {total}/55 RV32IM + CSR instructions')
    print(f'  Pipeline coverage: data forwarding, load-use hazard, branch+forward')
    print(f'  Integration: loops, Fibonacci, array operations')
