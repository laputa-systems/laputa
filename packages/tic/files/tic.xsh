#!/bin/xsh
# tic: compile terminfo source into ncurses' binary terminfo database.
#
#   tic -x [-o DIR] [-e NAME[,NAME...]] FILE
#
# This is a port of the compiler path of ncurses 6.6's `tic -x`, written so that
# the files it writes are byte-identical to the real tic's.  It reproduces the
# ncurses scanner (continuation lines, `#` comment lines, `.cap` commented-out
# capabilities, string escapes), `use=` resolution with ncurses' merge and
# cancellation rules, the extended-capability alignment, tic's write-time
# `%{n}` to `%'c'` rewrite, and the legacy (magic 0432) and 32-bit-number
# (magic 01036) object formats.  Aliases become hard links, as tic makes them.
#
# Deliberate differences from tic, each of which tic itself handles in a way
# that depends on the machine rather than the input:
# - termcap-syntax source is rejected (Laputa compiles terminfo source only);
# - two entries sharing a name are rejected (tic's collision check compares
#   heap addresses, so whether it fires depends on malloc);
# - a `use=` that names no entry in the source is rejected instead of being
#   looked up in whatever terminfo database the build host happens to have;
# - an entry larger than 32768 bytes is rejected instead of skipped;
# - writing into a directory that already holds entries replaces each path
#   this run writes, without tic's file-timestamp heuristics.

error TicError = Usage | Source | Resolve | Output

const BOOLEAN = 0
const NUMBER = 1
const STRING = 2
const CANCEL = 3
const NAMES = 4
const UNDEF = 5
const EOF_TOKEN = -1

const ABSENT_NUMERIC = -1
const CANCELLED = -2
const TRUE_BOOLEAN = 1
const FALSE_BOOLEAN = 0

const MAGIC = 0o432
const MAGIC2 = 0o1036
const MAX_ENTRY_SIZE = 32768
const MAX_NAME_SIZE = 512
const HARD_MAX_USES = 40
const MAX_NUMBER = 2147483647
const MAX_SHORT = 32767

# tic synthesizes this alternate-character map for entries that can switch
# character sets but describe no map.
const VT_ACSC = "``aaffggiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~"

# The capability table.  The first block is every row of ncurses 6.6's
# include/Caps, reduced to its first three columns (variable name, terminfo
# name, type), in file order: that order is the binary format's capability
# index order.  The rows after it are the `infoalias` and `userdef` rows of
# include/Caps-ncurses, reduced the same way.  Regenerate both blocks from an
# ncurses source tree with
#   awk '!/^#/ && NF {print $1, $2, $3}' include/Caps
#   awk '$1 == "infoalias" || $1 == "userdef" {print $1, $2, $3}' include/Caps-ncurses
# The tic package build checks this text against the pinned ncurses tarball.
# The standard capability rows of include/Caps.
const standard_caps_rows = r"""
auto_left_margin bw bool
auto_right_margin am bool
no_esc_ctlc xsb bool
ceol_standout_glitch xhp bool
eat_newline_glitch xenl bool
erase_overstrike eo bool
generic_type gn bool
hard_copy hc bool
has_meta_key km bool
has_status_line hs bool
insert_null_glitch in bool
memory_above da bool
memory_below db bool
move_insert_mode mir bool
move_standout_mode msgr bool
over_strike os bool
status_line_esc_ok eslok bool
dest_tabs_magic_smso xt bool
tilde_glitch hz bool
transparent_underline ul bool
xon_xoff xon bool
needs_xon_xoff nxon bool
prtr_silent mc5i bool
hard_cursor chts bool
non_rev_rmcup nrrmc bool
no_pad_char npc bool
non_dest_scroll_region ndscr bool
can_change ccc bool
back_color_erase bce bool
hue_lightness_saturation hls bool
col_addr_glitch xhpa bool
cr_cancels_micro_mode crxm bool
has_print_wheel daisy bool
row_addr_glitch xvpa bool
semi_auto_right_margin sam bool
cpi_changes_res cpix bool
lpi_changes_res lpix bool
columns cols num
init_tabs it num
lines lines num
lines_of_memory lm num
magic_cookie_glitch xmc num
padding_baud_rate pb num
virtual_terminal vt num
width_status_line wsl num
num_labels nlab num
label_height lh num
label_width lw num
max_attributes ma num
maximum_windows wnum num
max_colors colors num
max_pairs pairs num
no_color_video ncv num
buffer_capacity bufsz num
dot_vert_spacing spinv num
dot_horz_spacing spinh num
max_micro_address maddr num
max_micro_jump mjump num
micro_col_size mcs num
micro_line_size mls num
number_of_pins npins num
output_res_char orc num
output_res_line orl num
output_res_horz_inch orhi num
output_res_vert_inch orvi num
print_rate cps num
wide_char_size widcs num
buttons btns num
bit_image_entwining bitwin num
bit_image_type bitype num
back_tab cbt str
bell bel str
carriage_return cr str
change_scroll_region csr str
clear_all_tabs tbc str
clear_screen clear str
clr_eol el str
clr_eos ed str
column_address hpa str
command_character cmdch str
cursor_address cup str
cursor_down cud1 str
cursor_home home str
cursor_invisible civis str
cursor_left cub1 str
cursor_mem_address mrcup str
cursor_normal cnorm str
cursor_right cuf1 str
cursor_to_ll ll str
cursor_up cuu1 str
cursor_visible cvvis str
delete_character dch1 str
delete_line dl1 str
dis_status_line dsl str
down_half_line hd str
enter_alt_charset_mode smacs str
enter_blink_mode blink str
enter_bold_mode bold str
enter_ca_mode smcup str
enter_delete_mode smdc str
enter_dim_mode dim str
enter_insert_mode smir str
enter_secure_mode invis str
enter_protected_mode prot str
enter_reverse_mode rev str
enter_standout_mode smso str
enter_underline_mode smul str
erase_chars ech str
exit_alt_charset_mode rmacs str
exit_attribute_mode sgr0 str
exit_ca_mode rmcup str
exit_delete_mode rmdc str
exit_insert_mode rmir str
exit_standout_mode rmso str
exit_underline_mode rmul str
flash_screen flash str
form_feed ff str
from_status_line fsl str
init_1string is1 str
init_2string is2 str
init_3string is3 str
init_file if str
insert_character ich1 str
insert_line il1 str
insert_padding ip str
key_backspace kbs str
key_catab ktbc str
key_clear kclr str
key_ctab kctab str
key_dc kdch1 str
key_dl kdl1 str
key_down kcud1 str
key_eic krmir str
key_eol kel str
key_eos ked str
key_f0 kf0 str
key_f1 kf1 str
key_f10 kf10 str
key_f2 kf2 str
key_f3 kf3 str
key_f4 kf4 str
key_f5 kf5 str
key_f6 kf6 str
key_f7 kf7 str
key_f8 kf8 str
key_f9 kf9 str
key_home khome str
key_ic kich1 str
key_il kil1 str
key_left kcub1 str
key_ll kll str
key_npage knp str
key_ppage kpp str
key_right kcuf1 str
key_sf kind str
key_sr kri str
key_stab khts str
key_up kcuu1 str
keypad_local rmkx str
keypad_xmit smkx str
lab_f0 lf0 str
lab_f1 lf1 str
lab_f10 lf10 str
lab_f2 lf2 str
lab_f3 lf3 str
lab_f4 lf4 str
lab_f5 lf5 str
lab_f6 lf6 str
lab_f7 lf7 str
lab_f8 lf8 str
lab_f9 lf9 str
meta_off rmm str
meta_on smm str
newline nel str
pad_char pad str
parm_dch dch str
parm_delete_line dl str
parm_down_cursor cud str
parm_ich ich str
parm_index indn str
parm_insert_line il str
parm_left_cursor cub str
parm_right_cursor cuf str
parm_rindex rin str
parm_up_cursor cuu str
pkey_key pfkey str
pkey_local pfloc str
pkey_xmit pfx str
print_screen mc0 str
prtr_off mc4 str
prtr_on mc5 str
repeat_char rep str
reset_1string rs1 str
reset_2string rs2 str
reset_3string rs3 str
reset_file rf str
restore_cursor rc str
row_address vpa str
save_cursor sc str
scroll_forward ind str
scroll_reverse ri str
set_attributes sgr str
set_tab hts str
set_window wind str
tab ht str
to_status_line tsl str
underline_char uc str
up_half_line hu str
init_prog iprog str
key_a1 ka1 str
key_a3 ka3 str
key_b2 kb2 str
key_c1 kc1 str
key_c3 kc3 str
prtr_non mc5p str
char_padding rmp str
acs_chars acsc str
plab_norm pln str
key_btab kcbt str
enter_xon_mode smxon str
exit_xon_mode rmxon str
enter_am_mode smam str
exit_am_mode rmam str
xon_character xonc str
xoff_character xoffc str
ena_acs enacs str
label_on smln str
label_off rmln str
key_beg kbeg str
key_cancel kcan str
key_close kclo str
key_command kcmd str
key_copy kcpy str
key_create kcrt str
key_end kend str
key_enter kent str
key_exit kext str
key_find kfnd str
key_help khlp str
key_mark kmrk str
key_message kmsg str
key_move kmov str
key_next knxt str
key_open kopn str
key_options kopt str
key_previous kprv str
key_print kprt str
key_redo krdo str
key_reference kref str
key_refresh krfr str
key_replace krpl str
key_restart krst str
key_resume kres str
key_save ksav str
key_suspend kspd str
key_undo kund str
key_sbeg kBEG str
key_scancel kCAN str
key_scommand kCMD str
key_scopy kCPY str
key_screate kCRT str
key_sdc kDC str
key_sdl kDL str
key_select kslt str
key_send kEND str
key_seol kEOL str
key_sexit kEXT str
key_sfind kFND str
key_shelp kHLP str
key_shome kHOM str
key_sic kIC str
key_sleft kLFT str
key_smessage kMSG str
key_smove kMOV str
key_snext kNXT str
key_soptions kOPT str
key_sprevious kPRV str
key_sprint kPRT str
key_sredo kRDO str
key_sreplace kRPL str
key_sright kRIT str
key_srsume kRES str
key_ssave kSAV str
key_ssuspend kSPD str
key_sundo kUND str
req_for_input rfi str
key_f11 kf11 str
key_f12 kf12 str
key_f13 kf13 str
key_f14 kf14 str
key_f15 kf15 str
key_f16 kf16 str
key_f17 kf17 str
key_f18 kf18 str
key_f19 kf19 str
key_f20 kf20 str
key_f21 kf21 str
key_f22 kf22 str
key_f23 kf23 str
key_f24 kf24 str
key_f25 kf25 str
key_f26 kf26 str
key_f27 kf27 str
key_f28 kf28 str
key_f29 kf29 str
key_f30 kf30 str
key_f31 kf31 str
key_f32 kf32 str
key_f33 kf33 str
key_f34 kf34 str
key_f35 kf35 str
key_f36 kf36 str
key_f37 kf37 str
key_f38 kf38 str
key_f39 kf39 str
key_f40 kf40 str
key_f41 kf41 str
key_f42 kf42 str
key_f43 kf43 str
key_f44 kf44 str
key_f45 kf45 str
key_f46 kf46 str
key_f47 kf47 str
key_f48 kf48 str
key_f49 kf49 str
key_f50 kf50 str
key_f51 kf51 str
key_f52 kf52 str
key_f53 kf53 str
key_f54 kf54 str
key_f55 kf55 str
key_f56 kf56 str
key_f57 kf57 str
key_f58 kf58 str
key_f59 kf59 str
key_f60 kf60 str
key_f61 kf61 str
key_f62 kf62 str
key_f63 kf63 str
clr_bol el1 str
clear_margins mgc str
set_left_margin smgl str
set_right_margin smgr str
label_format fln str
set_clock sclk str
display_clock dclk str
remove_clock rmclk str
create_window cwin str
goto_window wingo str
hangup hup str
dial_phone dial str
quick_dial qdial str
tone tone str
pulse pulse str
flash_hook hook str
fixed_pause pause str
wait_tone wait str
user0 u0 str
user1 u1 str
user2 u2 str
user3 u3 str
user4 u4 str
user5 u5 str
user6 u6 str
user7 u7 str
user8 u8 str
user9 u9 str
orig_pair op str
orig_colors oc str
initialize_color initc str
initialize_pair initp str
set_color_pair scp str
set_foreground setf str
set_background setb str
change_char_pitch cpi str
change_line_pitch lpi str
change_res_horz chr str
change_res_vert cvr str
define_char defc str
enter_doublewide_mode swidm str
enter_draft_quality sdrfq str
enter_italics_mode sitm str
enter_leftward_mode slm str
enter_micro_mode smicm str
enter_near_letter_quality snlq str
enter_normal_quality snrmq str
enter_shadow_mode sshm str
enter_subscript_mode ssubm str
enter_superscript_mode ssupm str
enter_upward_mode sum str
exit_doublewide_mode rwidm str
exit_italics_mode ritm str
exit_leftward_mode rlm str
exit_micro_mode rmicm str
exit_shadow_mode rshm str
exit_subscript_mode rsubm str
exit_superscript_mode rsupm str
exit_upward_mode rum str
micro_column_address mhpa str
micro_down mcud1 str
micro_left mcub1 str
micro_right mcuf1 str
micro_row_address mvpa str
micro_up mcuu1 str
order_of_pins porder str
parm_down_micro mcud str
parm_left_micro mcub str
parm_right_micro mcuf str
parm_up_micro mcuu str
select_char_set scs str
set_bottom_margin smgb str
set_bottom_margin_parm smgbp str
set_left_margin_parm smglp str
set_right_margin_parm smgrp str
set_top_margin smgt str
set_top_margin_parm smgtp str
start_bit_image sbim str
start_char_set_def scsd str
stop_bit_image rbim str
stop_char_set_def rcsd str
subscript_characters subcs str
superscript_characters supcs str
these_cause_cr docr str
zero_motion zerom str
char_set_names csnm str
key_mouse kmous str
mouse_info minfo str
req_mouse_pos reqmp str
get_mouse getm str
set_a_foreground setaf str
set_a_background setab str
pkey_plab pfxl str
device_type devt str
code_set_init csin str
set0_des_seq s0ds str
set1_des_seq s1ds str
set2_des_seq s2ds str
set3_des_seq s3ds str
set_lr_margin smglr str
set_tb_margin smgtb str
bit_image_repeat birep str
bit_image_newline binel str
bit_image_carriage_return bicr str
color_names colornm str
define_bit_image_region defbi str
end_bit_image_region endbi str
set_color_band setcolor str
set_page_length slines str
display_pc_char dispc str
enter_pc_charset_mode smpch str
exit_pc_charset_mode rmpch str
enter_scancode_mode smsc str
exit_scancode_mode rmsc str
pc_term_options pctrm str
scancode_escape scesc str
alt_scancode_esc scesa str
enter_horizontal_hl_mode ehhlm str
enter_left_hl_mode elhlm str
enter_low_hl_mode elohlm str
enter_right_hl_mode erhlm str
enter_top_hl_mode ethlm str
enter_vertical_hl_mode evhlm str
set_a_attributes sgr1 str
set_pglen_inch slength str
termcap_init2 OTi2 str
termcap_reset OTrs str
magic_cookie_glitch_ul OTug num
backspaces_with_bs OTbs bool
crt_no_scrolling OTns bool
no_correctly_working_cr OTnc bool
carriage_return_delay OTdC num
new_line_delay OTdN num
linefeed_if_not_lf OTnl str
backspace_if_not_bs OTbc str
gnu_has_meta_key OTMT bool
linefeed_is_newline OTNL bool
backspace_delay OTdB num
horizontal_tab_delay OTdT num
number_of_function_keys OTkn num
other_non_function_keys OTko str
arrow_key_map OTma str
has_hardware_tabs OTpt bool
return_does_clr_eol OTxr bool
acs_ulcorner OTG2 str
acs_llcorner OTG3 str
acs_urcorner OTG1 str
acs_lrcorner OTG4 str
acs_ltee OTGR str
acs_rtee OTGL str
acs_btee OTGU str
acs_ttee OTGD str
acs_hline OTGH str
acs_vline OTGV str
acs_plus OTGC str
memory_lock meml str
memory_unlock memu str
box_chars_1 box1 str
"""

# The `infoalias` and `userdef` rows of include/Caps-ncurses.
const ncurses_caps_rows = r"""
infoalias font0 s0ds
infoalias font1 s1ds
infoalias font2 s2ds
infoalias font3 s3ds
infoalias kbtab kcbt
infoalias ksel kslt
userdef CO num
userdef E3 str
userdef NQ bool
userdef RGB bool
userdef RGB num
userdef RGB str
userdef TS str
userdef U8 num
userdef XM str
userdef grbom str
userdef gsbom str
userdef xm str
userdef xm str
userdef xm str
userdef xm str
userdef xm str
userdef xm str
userdef xm str
userdef xm str
userdef xm str
userdef Rmol str
userdef Smol str
userdef blink2 str
userdef norm str
userdef opaq str
userdef setal str
userdef smul2 str
userdef AN bool
userdef AX bool
userdef C0 str
userdef C8 bool
userdef CE str
userdef CS str
userdef E0 str
userdef G0 bool
userdef KJ str
userdef OL num
userdef S0 str
userdef TF bool
userdef WS str
userdef XC str
userdef XT bool
userdef Z0 str
userdef Z1 str
userdef Cr str
userdef Cs str
userdef Csr str
userdef Ms str
userdef Se str
userdef Smulx str
userdef Ss str
userdef rmxx str
userdef smxx str
userdef BD str
userdef BE str
userdef PE str
userdef PS str
userdef RV str
userdef XR str
userdef XF bool
userdef fd str
userdef fe str
userdef rv str
userdef xr str
userdef csl str
userdef kDC3 str
userdef kDC4 str
userdef kDC5 str
userdef kDC6 str
userdef kDC7 str
userdef kDN str
userdef kDN3 str
userdef kDN4 str
userdef kDN5 str
userdef kDN6 str
userdef kDN7 str
userdef kEND3 str
userdef kEND4 str
userdef kEND5 str
userdef kEND6 str
userdef kEND7 str
userdef kHOM3 str
userdef kHOM4 str
userdef kHOM5 str
userdef kHOM6 str
userdef kHOM7 str
userdef kIC3 str
userdef kIC4 str
userdef kIC5 str
userdef kIC6 str
userdef kIC7 str
userdef kLFT3 str
userdef kLFT4 str
userdef kLFT5 str
userdef kLFT6 str
userdef kLFT7 str
userdef kNXT3 str
userdef kNXT4 str
userdef kNXT5 str
userdef kNXT6 str
userdef kNXT7 str
userdef kPRV3 str
userdef kPRV4 str
userdef kPRV5 str
userdef kPRV6 str
userdef kPRV7 str
userdef kRIT3 str
userdef kRIT4 str
userdef kRIT5 str
userdef kRIT6 str
userdef kRIT7 str
userdef kUP str
userdef kUP3 str
userdef kUP4 str
userdef kUP5 str
userdef kUP6 str
userdef kUP7 str
userdef ka2 str
userdef kb1 str
userdef kb3 str
userdef kc2 str
userdef kxIN str
userdef kxOUT str
"""

type CapRef = {kind: Int, index: Int}

type CapTable = {
  info_names: Map[Str, CapRef],
  full_names: Map[Str, CapRef],
  aliases: Map[Str, Str],
  user_types: Map[Str, Int],
  acsc: Int,
  smacs: Int,
  rmacs: Int,
  box1: Int,
}

# A string capability slot.  Standard strings are kept only when present or
# cancelled; extended strings are positional and may be absent.
enum StrCap { Absent, Cancelled, Text(Bytes) }

# Extended (user-defined) capabilities in ncurses' positional form: `names`
# lists the boolean, then numeric, then string names, each group sorted, and
# the value lists line up with their group.  ncurses' alignment and
# cancellation code indexes this flat list directly, and its edge cases depend
# on that layout, so the layout is kept rather than a map.
type Ext = {
  names: List[Str],
  nb: Int,
  nn: Int,
  ns: Int,
  bools: List[Int],
  nums: List[Int],
  strs: List[StrCap],
}

# A terminal description.  Standard booleans hold TRUE or CANCELLED, numbers a
# value or CANCELLED, strings Cancelled or Text; a missing key is absent.
type Term = {
  names: Str,
  bools: Map[Int, Int],
  nums: Map[Int, Int],
  strs: Map[Int, StrCap],
  ext: Ext,
}

type Entry = {term: Term, uses: List[Str], line: Int}

type Token = {kind: Int, name: Str, number: Int, text: Bytes?, line: Int}

type ExtRef = {kind: Int, pos: Int}

type CLong = {value: Int, end: Int}

type ExtSpan = {first: Int, last: Int}

type Extended = {ext: Ext, ref: ExtRef}

type Inserted = {ext: Ext, pos: Int}

type Aligned = {to: Ext, from: Ext}

pure is_digit(c: Int) -> Bool {
  c >= 48 and c <= 57
}

pure is_octal(c: Int) -> Bool {
  c >= 48 and c <= 55
}

pure is_lower(c: Int) -> Bool {
  c >= 97 and c <= 122
}

pure is_alnum(c: Int) -> Bool {
  (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
}

pure is_white(c: Int) -> Bool {
  c == 32 or c == 9
}

pure is_space(c: Int) -> Bool {
  c == 32 or (c >= 9 and c <= 13)
}

pure is_print(c: Int) -> Bool {
  c >= 32 and c <= 126
}

# The user-capability type bits, standing in for ncurses' `1 << type` masks.
pure kind_bit(kind: Int) -> Int {
  if kind == BOOLEAN {
    1
  } else if kind == NUMBER {
    2
  } else {
    4
  }
}

pure has_bit(mask: Int, bit: Int) -> Bool {
  mask / bit % 2 == 1
}

pure empty_ext() -> Ext {
  Ext(names: [], nb: 0, nn: 0, ns: 0, bools: [], nums: [], strs: [])
}

pure empty_term(names: Str) -> Term {
  Term(names:, bools: {}, nums: {}, strs: {}, ext: empty_ext())
}

pure is_cancelled(value: StrCap) -> Bool {
  match value {
    Cancelled => true
    else => false
  }
}

pure is_absent(value: StrCap) -> Bool {
  match value {
    Absent => true
    else => false
  }
}

pure text_of(value: StrCap) -> Bytes? {
  match value {
    Text(text) => text
    else => null
  }
}

# The type column of a capability row, or -1.
pure cap_kind(type_name: Str) -> Int {
  match type_name {
    "bool" => BOOLEAN
    "num" => NUMBER
    "str" => STRING
    else => -1
  }
}

proc parse_cap_table(standard_rows: Str, ncurses_rows: Str) [error] -> Result[CapTable] {
  var info_names: Map[Str, CapRef] = {}
  var full_names: Map[Str, CapRef] = {}
  var counts = [0, 0, 0]

  for row in standard_rows.split("\n") {
    let fields = row.fields()
    if fields.is_empty() {
      continue
    }

    guard fields.len() == 3 else {
      return Err(TicError.Source(f"malformed capability row: {row}"))
    }

    let kind = cap_kind(fields[2])
    guard kind >= 0 else {
      return Err(TicError.Source(f"unknown capability type in row: {row}"))
    }

    let cap = CapRef(kind:, index: counts[kind])
    counts[kind] = counts[kind] + 1
    info_names[fields[1]] = cap
    full_names[fields[0]] = cap
  }

  var aliases: Map[Str, Str] = {}
  var user_types: Map[Str, Int] = {}
  for row in ncurses_rows.split("\n") {
    let fields = row.fields()
    if fields.is_empty() {
      continue
    }

    guard fields.len() == 3 else {
      return Err(TicError.Source(f"malformed ncurses capability row: {row}"))
    }

    if fields[0] == "infoalias" {
      aliases[fields[1]] = fields[2]
    } else if fields[0] == "userdef" {
      let kind = cap_kind(fields[2])
      guard kind >= 0 else {
        return Err(TicError.Source(f"unknown user capability type in row: {row}"))
      }

      let bit = kind_bit(kind)

      let mask = user_types.get(fields[1]) ?? 0
      if ! has_bit(mask, bit) {
        user_types[fields[1]] = mask + bit
      }
    } else {
      return Err(TicError.Source(f"unexpected ncurses capability row: {row}"))
    }
  }

  CapTable(
    info_names:,
    full_names:,
    aliases:,
    user_types:,
    acsc: info_names["acsc"].index,
    smacs: info_names["smacs"].index,
    rmacs: info_names["rmacs"].index,
    box1: info_names["box1"].index,
  )
}

# The scanner reads a character stream that already reflects ncurses'
# line reader: `#` lines are gone, each line's leading blanks are stripped,
# CR LF is LF, and the text ends with a newline.  `cols` holds, per stream
# byte, the column ncurses' reader reports after reading it, clamped to 3 (the
# scanner only distinguishes columns 1 and 2 from the rest): column 1 marks
# the first character of a line that had no leading blanks.
type CharStream = {chars: Str, cols: Str, lines: List[Int]}

pure threes(count: Int) -> Str {
  var text = "3333333333333333"
  while text.byte_len() < count {
    text = text + text
  }

  text.byte_slice(0, count)
}

type StreamLine = {body: Str, cols: Str, number: Int}

# One source line as ncurses' reader delivers it: leading blanks stripped,
# CR LF made LF, with the column of each remaining byte.
pure stream_line(raw: Str, number: Int) -> StreamLine {
  let line = if raw.ends_with("\r") { raw.byte_slice(0, raw.byte_len() - 1) } else { raw }
  var lead = 0
  var start = 0
  let length = line.byte_len()
  while start < length {
    let c = line.byte_at(start) ?? 0
    if c == 9 {
      lead = lead - lead % 8 + 8
    } else if c == 32 {
      lead += 1
    } else {
      break
    }

    start += 1
  }

  let body = line.byte_slice(start) + "\n"
  let size = body.byte_len()
  let first = if lead + 1 > 3 { 3 } else { lead + 1 }
  var cols = f"{first}"
  if size > 1 {
    let second = if lead == 0 and body.byte_at(1) != 9 { 2 } else { 3 }
    cols = cols + f"{second}" + threes(size - 2)
  }

  StreamLine(body:, cols:, number:)
}

pure char_stream(source: Str) -> CharStream {
  let text = if source.ends_with("\n") { source } else { source + "\n" }
  let raw_lines = text.split("\n")
  let count = raw_lines.len() - 1
  # `#` in the first column makes the whole line a comment.
  let kept = [stream_line(raw_lines[k], k + 1) for k in range(count) if raw_lines[k].byte_at(0) != 35]
  CharStream(
    chars: [line.body for line in kept].join(""),
    cols: [line.cols for line in kept].join(""),
    lines: [line.number for line in kept],
  )
}

pure char_at(text: Str, index: Int) -> Int {
  text.byte_at(index) ?? -1
}

# The last non-blank character of the rest of the current line (from `index`
# through its newline), or the one `from_end` places before it.
pure last_char(chars: Str, index: Int, from_end: Int) -> Int {
  var end = index
  while (chars.byte_at(end) ?? 10) != 10 {
    end += 1
  }

  var j = end
  while j >= index {
    let c = chars.byte_at(j) ?? 0
    if ! is_space(c) {
      if from_end <= j - index {
        return chars.byte_at(j - from_end) ?? 0
      }

      return 0
    }

    j -= 1
  }

  0
}

# strtol(text + start, base 0): the value and the offset just past it, or
# `start` itself when no number is there.
pure parse_c_long(text: Bytes, start: Int) -> CLong {
  var i = start
  while is_space(text.byte_at(i) ?? 0) {
    i += 1
  }

  var negative = false
  let sign = text.byte_at(i) ?? 0
  if sign == 43 or sign == 45 {
    negative = sign == 45
    i += 1
  }

  var base = 10
  let c0 = text.byte_at(i) ?? 0
  let c1 = text.byte_at(i + 1) ?? 0
  let c2 = text.byte_at(i + 2) ?? 0
  let hex_next = is_digit(c2) or (c2 >= 97 and c2 <= 102) or (c2 >= 65 and c2 <= 70)
  if c0 == 48 and (c1 == 120 or c1 == 88) and hex_next {
    base = 16
    i += 2
  } else if c0 == 48 {
    base = 8
  }

  let digits_start = i
  var value = 0
  var saturated = false
  loop {
    let c = text.byte_at(i) ?? 0
    let digit = if is_digit(c) {
      c - 48
    } else if c >= 97 and c <= 122 {
      c - 87
    } else if c >= 65 and c <= 90 {
      c - 55
    } else {
      99
    }

    if digit >= base {
      break
    }

    if ! saturated {
      value = value * base + digit
      if value > 9223372036854775807 / 64 {
        saturated = true
      }
    }

    i += 1
  }

  if i == digits_start {
    return {value: 0, end: start}
  }

  {value: if negative { -value } else { value }, end: i}
}

# Report a malformed source from inside the scanner's stream.
proc source_error(message: Str) [error] -> Result[Unit] {
  Err(TicError.Source(message))
}

stream scan(source: Str, table: CapTable) -> Stream[Token] {
  let input = char_stream(source)
  let chars = input.chars
  let cols = input.cols
  var i = 0
  var col = 0
  var c = 0
  var line_index = 0
  # The separator follows the syntax of the most recent names line; it is
  # unset before the first one.
  var separator = 0

  loop {
    # Skip blanks and newlines between tokens.
    loop {
      c = chars.byte_at(i) ?? -1
      if c < 0 {
        break
      }

      col = (cols.byte_at(i) ?? 49) - 48
      i += 1
      if c == 10 {
        line_index += 1
      }

      if ! (c == 10 or is_white(c)) {
        break
      }
    }

    # A backslash before a newline continues a termcap line.
    if c == 92 {
      loop {
        c = chars.byte_at(i) ?? -1
        if c < 0 {
          break
        }

        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if c == 10 {
          line_index += 1
        }

        if ! (c == 10 or is_white(c)) {
          break
        }
      }
    }

    if c < 0 {
      break
    }

    # A leading `.` comments out the capability that follows.
    var dot = false
    if c == 46 {
      dot = true
      loop {
        c = chars.byte_at(i) ?? -1
        if c < 0 {
          break
        }

        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if c == 10 {
          line_index += 1
        }

        if ! (c == 46 or is_white(c)) {
          break
        }
      }

      if c < 0 {
        break
      }
    }

    let line = input.lines.get(line_index) ?? 0
    if ! is_alnum(c) and c != 64 and c != 37 and c != 38 and c != 42 and c != 33 and c != 35 {
      eprint f"tic: line {line}: illegal character (expected alphanumeric or @%&*!#) - {c}"
      # Panic mode: skip to the next separator.
      loop {
        let d = chars.byte_at(i) ?? -1
        if d < 0 {
          break
        }

        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if d == 10 {
          line_index += 1
        }

        if d == separator {
          break
        }
      }

      continue
    }

    if col == 1 {
      # A names line: everything up to the separator that ends the names.
      var tok: List[Int] = [c]
      var syntax = -1
      var after_name = -1
      loop {
        c = chars.byte_at(i) ?? -1
        if c < 0 {
          source_error(f"line {line}: premature end of file in names")
        }

        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if c == 10 {
          line_index += 1
          break
        }

        if c == 124 {
          if after_name < 0 {
            after_name = tok.len()
          }
        } else if c == 58 and last_char(chars, i, 0) != 44 {
          syntax = 0
          separator = 58
          break
        } else if c == 44 {
          syntax = 1
          separator = 44
          if after_name < 0 {
            break
          }

          let c0 = last_char(chars, i, 0)
          let c1 = last_char(chars, i, 1)
          if c1 != 58 and c0 != 92 and c0 != 58 {
            # A comma may sit inside the description.  Treat it as the end of
            # the names only when what follows looks like a capability.
            var s = i
            while is_space(char_at(chars, s)) and char_at(chars, s) != 10 {
              s += 1
            }

            var capability = false
            if is_lower(char_at(chars, s)) {
              let name_start = s
              while is_alnum(char_at(chars, s)) {
                s += 1
              }

              let after = char_at(chars, s)
              if after == 35 or after == 61 or after == 64 {
                capability = true
              } else if after == 44 {
                capability = chars.byte_slice(name_start, s - name_start) in table.info_names
              }
            }

            if capability {
              break
            }
          }
        } else if c == 92 {
          loop {
            c = chars.byte_at(i) ?? -1
            if c < 0 {
              break
            }

            col = (cols.byte_at(i) ?? 49) - 48
            i += 1
            if c == 10 {
              line_index += 1
            }

            if ! (c == 10 or is_white(c)) {
              break
            }
          }
        }

        if tok.len() < MAX_ENTRY_SIZE - 2 {
          tok += [c]
        } else {
          break
        }
      }

      if syntax != 1 {
        source_error(f"line {line}: termcap-syntax entries are not supported")
      }

      # Drop trailing blanks and commas.
      var keep = tok.len()
      while keep > 0 and (is_white(tok[keep - 1]) or tok[keep - 1] == 44) {
        keep -= 1
      }

      let names = bytes.from_ints(tok[0..keep])?.utf8()?
      if ! dot {
        yield Token(kind: NAMES, name: names, number: 0, text: null, line:)
      }

      continue
    }

    # A capability: its name, then the character that gives its type.
    let name_start = i - 1
    loop {
      c = chars.byte_at(i) ?? -1
      if c < 0 {
        break
      }

      col = (cols.byte_at(i) ?? 49) - 48
      i += 1
      if c == 10 {
        line_index += 1
      }

      if ! is_alnum(c) and c != 95 {
        break
      }
    }

    let name_end = if c < 0 { i } else { i - 1 }
    let name = chars.byte_slice(name_start, name_end - name_start)
    var token = Token(kind: UNDEF, name:, number: 0, text: null, line:)

    if c == 44 or c == 58 {
      if c != separator {
        source_error(f"line {line}: separator inconsistent with syntax")
      }

      token = {...token, kind: BOOLEAN}
    } else if c == 64 {
      c = chars.byte_at(i) ?? -1
      if c >= 0 {
        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if c == 10 {
          line_index += 1
        }
      }

      token = {...token, kind: CANCEL}
    } else if c == 35 {
      var digits: List[Int] = []
      loop {
        c = chars.byte_at(i) ?? -1
        if c < 0 {
          break
        }

        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if c == 10 {
          line_index += 1
        }

        if ! is_alnum(c) {
          break
        }

        digits += [c]
        if digits.len() >= 79 {
          break
        }
      }

      let parsed = parse_c_long(bytes.from_ints(digits)?, 0)
      let number = if parsed.value > MAX_NUMBER { MAX_NUMBER } else { parsed.value }
      token = {...token, kind: NUMBER, number}
    } else if c == 61 {
      # The string value, translating escapes as ncurses' _nc_trans_string.
      var out: List[Int] = []
      var last_ch = 0
      loop {
        c = chars.byte_at(i) ?? -1
        if c < 0 {
          break
        }

        col = (cols.byte_at(i) ?? 49) - 48
        i += 1
        if c == 10 {
          line_index += 1
        }

        if c == separator {
          break
        }

        if out.len() >= MAX_ENTRY_SIZE - 2 {
          source_error(f"line {line}: string value of {name} is too long")
        }

        var ignored = false
        if c == 94 and last_ch != 37 {
          c = chars.byte_at(i) ?? -1
          if c < 0 {
            source_error(f"line {line}: premature end of file in {name}")
          }

          col = (cols.byte_at(i) ?? 49) - 48
          i += 1
          if c == 10 {
            line_index += 1
          }

          if c == 63 {
            out += [127]
          } else {
            c = c % 32
            if c == 0 {
              c = 128
            }

            out += [c]
          }
        } else if c == 92 {
          c = chars.byte_at(i) ?? -1
          if c < 0 {
            source_error(f"line {line}: premature end of file in {name}")
          }

          col = (cols.byte_at(i) ?? 49) - 48
          i += 1
          if c == 10 {
            line_index += 1
          }

          if is_octal(c) {
            var number = c - 48
            var k = 0
            while k < 2 {
              c = chars.byte_at(i) ?? -1
              if c < 0 {
                source_error(f"line {line}: premature end of file in {name}")
              }

              col = (cols.byte_at(i) ?? 49) - 48
              i += 1
              if c == 10 {
                line_index += 1
              }

              if ! is_octal(c) and ! is_digit(c) {
                i -= 1
                col -= 1
                if c == 10 {
                  line_index -= 1
                }

                break
              }

              number = number * 8 + c - 48
              k += 1
            }

            number = number % 256
            if number == 0 {
              number = 128
            }

            out += [number]
          } else if c == 10 {
            # An escaped newline joins the next line into the string.
            continue
          } else {
            let translated = match c {
              69 => 27
              110 => 10
              114 => 13
              98 => 8
              102 => 12
              116 => 9
              92 => 92
              94 => 94
              44 => 44
              97 => 7
              101 => 27
              108 => 10
              115 => 32
              58 => 58
              else => c
            }

            # The \E \n \r \b \f \t \\ \^ \, forms leave `c` as the escape
            # letter; the \a \e \l \s \: forms and unknown escapes replace it.
            if c == 97 or c == 101 or c == 108 or c == 115 {
              c = translated
            }

            out += [translated]
          }
        } else if c == 10 {
          # Newlines inside a terminfo string are dropped.
          ignored = true
        } else {
          out += [c]
        }

        if ! ignored {
          if col <= 1 {
            # A character in the first column starts the next entry.
            i -= 1
            col -= 1
            if c == 10 {
              line_index -= 1
            }

            break
          }

          last_ch = c
        }
      }

      token = {...token, kind: STRING, text: bytes.from_ints(out)?}
    } else if c < 0 {
      token = {...token, kind: EOF_TOKEN}
    }

    if token.kind == EOF_TOKEN {
      break
    }

    if ! dot {
      yield token
    }
  }
}

# ncurses' rule for names that may appear in a names line or use= clause.
pure valid_entry_name(name: Str) -> Bool {
  var first = true
  var i = 0
  let n = name.byte_len()
  while i < n {
    let c = name.byte_at(i) ?? 0
    if c <= 32 or c > 126 or c == 47 or c == 92 or c == 124 or c == 61 or c == 44 or c == 58 {
      return false
    }

    if ! first and (c == 35 or c == 64) {
      return false
    }

    first = false
    i += 1
  }

  true
}

pure ext_count(ext: Ext) -> Int {
  ext.nb + ext.nn + ext.ns
}

pure ext_range(ext: Ext, kind: Int) -> ExtSpan {
  if kind == BOOLEAN {
    {first: 0, last: ext.nb}
  } else if kind == NUMBER {
    {first: ext.nb, last: ext.nb + ext.nn}
  } else {
    {first: ext.nb + ext.nn, last: ext_count(ext)}
  }
}

pure insert_at(items: List[Str], pos: Int, item: Str) -> List[Str] {
  items[0..pos] + [item] + items[pos..]
}

pure remove_at(items: List[Str], pos: Int) -> List[Str] {
  items[0..pos] + items[pos + 1..]
}

# Insert an extended name of `kind` with a default value at its sorted place
# within its group, as _nc_extend_names does; returns the slot of the name.
pure extend_names(ext: Ext, name: Str, kind: Int) -> Extended {
  if kind == CANCEL {
    var n = 0
    let total = ext_count(ext)
    while n < total {
      if ext.names[n] == name {
        # ncurses classifies the name by its flat position with `>` rather
        # than `>=`, so the first name of a group counts as the group before.
        let found = if n > ext.nb + ext.nn {
          STRING
        } else if n > ext.nb {
          NUMBER
        } else {
          BOOLEAN
        }

        return extend_names(ext, name, found)
      }

      n += 1
    }

    return extend_names(ext, name, STRING)
  }

  let range = ext_range(ext, kind)
  var offset = range.last
  var pos = range.last - range.first
  var found = false
  var n = range.first
  while n < range.last {
    let other = ext.names[n]
    if other == name {
      found = true
    }

    if other >= name {
      offset = n
      pos = n - range.first
      break
    }

    n += 1
  }

  if found {
    return {ext, ref: ExtRef(kind:, pos:)}
  }

  let names = insert_at(ext.names, offset, name)
  let grown = if kind == BOOLEAN {
    {...ext, names, nb: ext.nb + 1, bools: ext.bools[0..pos] + [FALSE_BOOLEAN] + ext.bools[pos..]}
  } else if kind == NUMBER {
    {...ext, names, nn: ext.nn + 1, nums: ext.nums[0..pos] + [ABSENT_NUMERIC] + ext.nums[pos..]}
  } else {
    {...ext, names, ns: ext.ns + 1, strs: ext.strs[0..pos] + [Absent] + ext.strs[pos..]}
  }

  {ext: grown, ref: ExtRef(kind:, pos:)}
}

pure find_ext_name(ext: Ext, name: Str, kind: Int) -> Int {
  let range = ext_range(ext, kind)
  var j = range.first
  while j < range.last {
    if ext.names[j] == name {
      return j
    }

    j += 1
  }

  -1
}

pure delete_ext_name(ext: Ext, name: Str, kind: Int) -> Ext? {
  let flat = find_ext_name(ext, name, kind)
  if flat < 0 {
    return null
  }

  let names = remove_at(ext.names, flat)
  if kind == BOOLEAN {
    {...ext, names, nb: ext.nb - 1, bools: ext.bools[0..flat] + ext.bools[flat + 1..]}
  } else if kind == NUMBER {
    let pos = flat - ext.nb
    {...ext, names, nn: ext.nn - 1, nums: ext.nums[0..pos] + ext.nums[pos + 1..]}
  } else {
    let pos = flat - ext.nb - ext.nn
    {...ext, names, ns: ext.ns - 1, strs: ext.strs[0..pos] + ext.strs[pos + 1..]}
  }
}

# Delete `name` from the `first` group, else from the `second`.
pure delete_either(ext: Ext, name: Str, first: Int, second: Int) -> Ext? {
  let removed = delete_ext_name(ext, name, first)
  if removed != null {
    return removed
  }

  delete_ext_name(ext, name, second)
}

# _nc_ins_ext_name: insert a name of `kind` unless that group has it already.
pure insert_ext_name(ext: Ext, name: Str, kind: Int) -> Inserted {
  let range = ext_range(ext, kind)
  var j = range.first
  while j < range.last {
    let other = ext.names[j]
    if name == other {
      return {ext, pos: j - range.first}
    }

    if name < other {
      break
    }

    j += 1
  }

  let names = insert_at(ext.names, j, name)
  let pos = j - range.first
  let grown = if kind == BOOLEAN {
    {...ext, names, nb: ext.nb + 1, bools: ext.bools[0..pos] + [FALSE_BOOLEAN] + ext.bools[pos..]}
  } else if kind == NUMBER {
    {...ext, names, nn: ext.nn + 1, nums: ext.nums[0..pos] + [ABSENT_NUMERIC] + ext.nums[pos..]}
  } else {
    {...ext, names, ns: ext.ns + 1, strs: ext.strs[0..pos] + [Absent] + ext.strs[pos..]}
  }

  {ext: grown, pos}
}

# adjust_cancels: a string-typed cancellation of a name that `other` defines
# as a boolean or number takes that type instead.  The loop bounds are fixed
# when it starts, exactly as in ncurses.
pure adjust_cancels(start: Ext, other: Ext) -> Ext {
  var ext = start
  let first = ext.nb + ext.nn
  let last = first + ext.ns
  var j = first
  while j < last {
    if j - first > ext.ns {
      break
    }

    let slot = j - first
    let cancelled = slot < ext.ns and is_cancelled(ext.strs[slot])
    if ! cancelled {
      j += 1
      continue
    }

    let name = ext.names[j]
    if find_ext_name(other, name, BOOLEAN) >= 0 {
      let removed = delete_either(ext, name, STRING, NUMBER)
      if removed != null {
        let inserted = insert_ext_name(removed, name, BOOLEAN)
        var bools = inserted.ext.bools
        bools[inserted.pos] = FALSE_BOOLEAN
        ext = {...inserted.ext, bools}
      } else {
        j += 1
      }
    } else if find_ext_name(other, name, NUMBER) >= 0 {
      let removed = delete_either(ext, name, STRING, BOOLEAN)
      if removed != null {
        let inserted = insert_ext_name(removed, name, NUMBER)
        var nums = inserted.ext.nums
        nums[inserted.pos] = CANCELLED
        ext = {...inserted.ext, nums}
      } else {
        j += 1
      }
    } else if find_ext_name(other, name, STRING) >= 0 {
      let removed = delete_either(ext, name, NUMBER, BOOLEAN)
      if removed != null {
        let inserted = insert_ext_name(removed, name, STRING)
        var strs = inserted.ext.strs
        strs[inserted.pos] = Cancelled
        ext = {...inserted.ext, strs}
      } else {
        j += 1
      }
    } else {
      j += 1
    }
  }

  ext
}

pure merge_names(a: List[Str], b: List[Str]) -> List[Str] {
  var out: List[Str] = []
  var i = 0
  var j = 0
  while i < a.len() and j < b.len() {
    if a[i] < b[j] {
      out += [a[i]]
      i += 1
    } else if a[i] > b[j] {
      out += [b[j]]
      j += 1
    } else {
      out += [a[i]]
      i += 1
      j += 1
    }
  }

  out + a[i..] + b[j..]
}

pure name_in(names: List[Str], from: Int, to: Int, name: Str) -> Bool {
  var n = from
  while n < to {
    if names[n] == name {
      return true
    }

    n += 1
  }

  false
}

# realign_data: lay `ext`'s values out over the merged name list.
pure realign(ext: Ext, merged: List[Str], eb: Int, en: Int, es: Int) -> Ext {
  var out = ext
  if ext.nb != eb {
    var bools: List[Int] = []
    var n = ext.nb - 1
    var m = eb - 1
    while m >= 0 {
      if name_in(ext.names, 0, ext.nb, merged[m]) {
        bools = [ext.bools[n]] + bools
        n -= 1
      } else {
        bools = [FALSE_BOOLEAN] + bools
      }

      m -= 1
    }

    out = {...out, nb: eb, bools}
  }

  if ext.nn != en {
    var nums: List[Int] = []
    var n = ext.nn - 1
    var m = en - 1
    while m >= 0 {
      if name_in(ext.names, ext.nb, ext.nb + ext.nn, merged[m + eb]) {
        nums = [ext.nums[n]] + nums
        n -= 1
      } else {
        nums = [ABSENT_NUMERIC] + nums
      }

      m -= 1
    }

    out = {...out, nn: en, nums}
  }

  if ext.ns != es {
    var strs: List[StrCap] = []
    var n = ext.ns - 1
    var m = es - 1
    while m >= 0 {
      if name_in(ext.names, ext.nb + ext.nn, ext_count(ext), merged[m + eb + en]) {
        strs = [ext.strs[n]] + strs
        n -= 1
      } else {
        strs = [Absent] + strs
      }

      m -= 1
    }

    out = {...out, ns: es, strs}
  }

  out
}

pure same_names(a: Ext, b: Ext) -> Bool {
  a.nb == b.nb and a.nn == b.nn and a.ns == b.ns and a.names == b.names
}

# _nc_align_termtype: give both sides the union of their extended names.
pure align(to_start: Ext, from_start: Ext) -> Aligned {
  var to = to_start
  var from = from_start
  let na = ext_count(to)
  let nb = ext_count(from)
  if na == 0 and nb == 0 {
    return {to, from}
  }

  if na == nb and same_names(to, from) {
    return {to, from}
  }

  if to.ns > 0 and from.nb + from.nn > 0 {
    to = adjust_cancels(to, from)
  }

  if from.ns > 0 and to.nb + to.nn > 0 {
    from = adjust_cancels(from, to)
  }

  let bools = merge_names(to.names[0..to.nb], from.names[0..from.nb])
  let nums = merge_names(to.names[to.nb..to.nb + to.nn], from.names[from.nb..from.nb + from.nn])
  let strs = merge_names(to.names[to.nb + to.nn..], from.names[from.nb + from.nn..])
  let merged = bools + nums + strs
  let total = merged.len()
  if na != total {
    to = {...realign(to, merged, bools.len(), nums.len(), strs.len()), names: merged}
  }

  if nb != total {
    from = {...realign(from, merged, bools.len(), nums.len(), strs.len()), names: merged}
  }

  {to, from}
}

# The keys of `to` followed by the keys only `from` has.
pure union_keys(to: List[Int], from: List[Int], present: Map[Int, Bool]) -> List[Int] {
  to + [key for key in from if key not in present]
}

pure merge_bools(to: Map[Int, Int], from: Map[Int, Int]) -> Map[Int, Int] {
  let present = {key: true for key in to.keys()}
  let keys = union_keys(to.keys(), from.keys(), present)
  let merged = [{key, value: merge_bool(to.get(key) ?? FALSE_BOOLEAN, from.get(key) ?? FALSE_BOOLEAN)} for key in keys]
  {item.key: item.value for item in merged if item.value != FALSE_BOOLEAN}
}

pure merge_bool(to: Int, from: Int) -> Int {
  if to == CANCELLED {
    to
  } else if from == CANCELLED {
    FALSE_BOOLEAN
  } else if from == TRUE_BOOLEAN {
    TRUE_BOOLEAN
  } else {
    to
  }
}

pure merge_nums(to: Map[Int, Int], from: Map[Int, Int]) -> Map[Int, Int] {
  let present = {key: true for key in to.keys()}
  let keys = union_keys(to.keys(), from.keys(), present)
  let merged = [{key, value: merge_num(to.get(key) ?? ABSENT_NUMERIC, from.get(key) ?? ABSENT_NUMERIC)} for key in keys]
  {item.key: item.value for item in merged if item.value != ABSENT_NUMERIC}
}

pure merge_num(to: Int, from: Int) -> Int {
  if to == CANCELLED {
    to
  } else if from == CANCELLED {
    ABSENT_NUMERIC
  } else if from != ABSENT_NUMERIC {
    from
  } else {
    to
  }
}

pure merge_strs(to: Map[Int, StrCap], from: Map[Int, StrCap]) -> Map[Int, StrCap] {
  let present = {key: true for key in to.keys()}
  let keys = union_keys(to.keys(), from.keys(), present)
  let merged = [{key, value: merge_str(to.get(key) ?? Absent, from.get(key) ?? Absent)} for key in keys]
  {item.key: item.value for item in merged if ! is_absent(item.value)}
}

pure merge_str(to: StrCap, from: StrCap) -> StrCap {
  if is_cancelled(to) {
    to
  } else if is_cancelled(from) {
    Absent
  } else if ! is_absent(from) {
    from
  } else {
    to
  }
}

# _nc_merge_entry: fill `to` from `from` (a use= target).  Cancelled slots of
# `to` stay cancelled; a cancellation in `from` clears the slot.
pure merge_term(to_term: Term, from_term: Term) -> Term {
  let aligned = align(to_term.ext, from_term.ext)
  var to = {...to_term, ext: aligned.to}
  let from = {...from_term, ext: aligned.from}

  let bools = merge_bools(to.bools, from.bools)
  let nums = merge_nums(to.nums, from.nums)
  let strs = merge_strs(to.strs, from.strs)

  var ext = to.ext
  var ext_bools = ext.bools
  var i = 0
  while i < from.ext.nb and i < ext.nb {
    if ext_bools[i] != CANCELLED {
      let value = from.ext.bools[i]
      if value == CANCELLED {
        ext_bools[i] = FALSE_BOOLEAN
      } else if value == TRUE_BOOLEAN {
        ext_bools[i] = TRUE_BOOLEAN
      }
    }

    i += 1
  }

  var ext_nums = ext.nums
  i = 0
  while i < from.ext.nn and i < ext.nn {
    if ext_nums[i] != CANCELLED {
      let value = from.ext.nums[i]
      if value == CANCELLED {
        ext_nums[i] = ABSENT_NUMERIC
      } else if value != ABSENT_NUMERIC {
        ext_nums[i] = value
      }
    }

    i += 1
  }

  var ext_strs = ext.strs
  i = 0
  while i < from.ext.ns and i < ext.ns {
    if ! is_cancelled(ext_strs[i]) {
      let value = from.ext.strs[i]
      if is_cancelled(value) {
        ext_strs[i] = Absent
      } else if ! is_absent(value) {
        ext_strs[i] = value
      }
    }

    i += 1
  }

  ext = {...ext, bools: ext_bools, nums: ext_nums, strs: ext_strs}
  {...to, bools, nums, strs, ext}
}

pure first_name(names: Str) -> Str {
  names.split("|")[0]
}

# postprocess_terminfo: AIX box1 characters become acsc pairs.
proc postprocess(term: Term, table: CapTable) -> Result[Term] {
  let box = text_of(term.strs.get(table.box1) ?? Absent)
  if box == null {
    return term
  }

  var out: List[Bytes] = []
  let acs = text_of(term.strs.get(table.acsc) ?? Absent)
  if acs != null {
    out += [acs]
  }

  let codes = b"lqkxjmwuvtn"
  var k = 0
  while k < 11 {
    let ch = box.byte_at(k)
    if ch != null {
      out += [bytes.from_ints([codes.byte_at(k) ?? 0, ch])?]
    }

    k += 1
  }

  let built = bytes.concat(out)
  if built.is_empty() {
    return term
  }

  eprint f"tic: {first_name(term.names)}: acsc string synthesized from AIX capabilities"
  var strs = term.strs
  strs[table.acsc] = Text(built)
  strs = strs.remove(table.box1)
  {...term, strs}
}

# A standard capability by terminfo name, by Caps-ncurses alias, or by its
# variable name, in the order ncurses tries them.
pure lookup_cap(table: CapTable, name: Str) -> CapRef? {
  if name in table.info_names {
    return table.info_names[name]
  }

  if name in table.aliases and table.aliases[name] in table.info_names {
    return table.info_names[table.aliases[name]]
  }

  if name in table.full_names {
    return table.full_names[name]
  }

  null
}

# One capability token of an entry, as _nc_parse_entry handles it.
proc apply_token(entry: Entry, token: Token, table: CapTable) [error] -> Result[Entry] {
  var term = entry.term
  var uses = entry.uses
  var kind = token.kind
  let name = token.name
  if name == "use" or name == "tc" {
    let target = if token.text != null { token.text.utf8() ?? "" } else { "" }
    if target == "" {
      eprint f"tic: line {token.line}: missing name for use-clause"
      return {...entry, term, uses}
    }

    if ! valid_entry_name(target) {
      eprint f"tic: line {token.line}: invalid name for use-clause \"{target}\""
      return {...entry, term, uses}
    }

    if uses.len() >= HARD_MAX_USES {
      eprint f"tic: line {token.line}: too many use-clauses, ignored \"{target}\""
      return {...entry, term, uses}
    }

    uses += [target]
    return {...entry, term, uses}
  }

  let cap = lookup_cap(table, name)

  var ext_ref: ExtRef? = null
  if cap == null {
    let mask = table.user_types.get(name) ?? 0
    if mask != 0 and kind < CANCEL and ! has_bit(mask, kind_bit(kind)) {
      eprint f"tic: line {token.line}: wrong type for user-defined capability {name}"
      return {...entry, term, uses}
    }

    if kind == BOOLEAN or kind == NUMBER or kind == STRING or kind == CANCEL {
      let extended = extend_names(term.ext, name, kind)
      term = {...term, ext: extended.ext}
      ext_ref = extended.ref
    } else {
      eprint f"tic: line {token.line}: unknown capability '{name}'"
      return {...entry, term, uses}
    }
  }

  let found_kind = if cap != null { cap.kind } else { (ext_ref ?? ExtRef(kind: 0, pos: 0)).kind }
  if kind != CANCEL and found_kind != kind {
    if kind == BOOLEAN and found_kind == STRING {
      # A string capability without `=` is an empty string.
      kind = STRING
    } else {
      eprint f"tic: line {token.line}: wrong type used for capability '{name}'"
      return {...entry, term, uses}
    }
  }

  let text = if kind == STRING { token.text ?? b"" } else { b"" }
  if cap != null {
    let index = cap.index
    if kind == CANCEL {
      if cap.kind == BOOLEAN {
        term = {...term, bools: term.bools.set(index, CANCELLED)}
      } else if cap.kind == NUMBER {
        term = {...term, nums: term.nums.set(index, CANCELLED)}
      } else {
        term = {...term, strs: term.strs.set(index, Cancelled)}
      }
    } else if kind == BOOLEAN {
      term = {...term, bools: term.bools.set(index, TRUE_BOOLEAN)}
    } else if kind == NUMBER {
      term = {...term, nums: term.nums.set(index, token.number)}
    } else {
      term = {...term, strs: term.strs.set(index, Text(text))}
    }
  } else {
    let ref = ext_ref ?? ExtRef(kind: 0, pos: 0)
    var ext = term.ext
    if ref.kind == BOOLEAN {
      var values = ext.bools
      values[ref.pos] = if kind == CANCEL { CANCELLED } else { TRUE_BOOLEAN }
      ext = {...ext, bools: values}
    } else if ref.kind == NUMBER {
      var values = ext.nums
      values[ref.pos] = if kind == CANCEL { CANCELLED } else { token.number }
      ext = {...ext, nums: values}
    } else {
      var values = ext.strs
      values[ref.pos] = if kind == CANCEL { Cancelled } else { Text(text) }
      ext = {...ext, strs: values}
    }

    term = {...term, ext}
  }

  {...entry, term, uses}
}

proc finish_entry(entry: Entry, table: CapTable) -> Result[Entry] {
  {...entry, term: postprocess(entry.term, table)?}
}

# _nc_parse_entry over the token stream: one Entry per names token.
proc parse_entries(tokens: Stream[Token], table: CapTable) -> Result[List[Entry]] {
  var entries: List[Entry] = []
  var started = false
  var entry = Entry(empty_term(""), [], 0)
  for token in tokens {
    if token.kind == NAMES {
      if started {
        entries += [finish_entry(entry, table)?]
      }

      guard is_alnum(token.name.byte_at(0) ?? 0) else {
        return Err(TicError.Source(f"line {token.line}: terminal names must start with letter or digit"))
      }

      if ! valid_entry_name(first_name(token.name)) {
        eprint f"tic: line {token.line}: invalid entry name \"{first_name(token.name)}\""
      }

      started = true
      entry = Entry(empty_term(token.name), [], token.line)
      continue
    }

    guard started else {
      return Err(TicError.Source(f"line {token.line}: entry does not start with terminal names in column one"))
    }

    entry = apply_token(entry, token, table)?
  }

  if started {
    entries += [finish_entry(entry, table)?]
  }

  entries
}

pure entry_names(names: Str) -> List[Str] {
  names.split("|")
}

# The distinct fields of a names line, in order.
pure unique_names(names: Str) -> List[Str] {
  let fields = entry_names(names)
  [fields[k] for k in range(fields.len()) if fields[k] not in fields[0..k]]
}

# Merge one entry's use= targets into it: start from the entry, merge its uses
# from last to first (so earlier uses win), then the entry itself on top.
pure merge_uses(term: Term, targets: List[Term]) -> Term {
  var merged = term
  var n = targets.len() - 1
  while n >= 0 {
    merged = merge_term(merged, targets[n])
    n -= 1
  }

  if ! targets.is_empty() {
    merged = merge_term(merged, term)
  }

  merged
}

proc resolve(entries: List[Entry], table: CapTable) [error] -> Result[List[Term]] {
  # Every name, alias, and description of every entry, to its entries in
  # source order.  A use= resolves to the last other entry carrying the name.
  let pairs = [
    {name, index}
    for index in range(entries.len())
    for name in unique_names(entries[index].term.names)
  ]
  let by_name = {owners.key: [pair.index for pair in owners.items] for owners in pairs |> group-by .name}
  var index = 0
  index = 0
  for entry in entries {
    let names = entry_names(entry.term.names)
    let aliases = names[0..names.len() - 1]
    let own = if names.len() == 1 { names } else { aliases }
    for name in own {
      let owners = by_name.get(name) ?? []
      for owner in owners {
        if owner != index {
          let other = entries[owner]
          let other_names = entry_names(other.term.names)
          let other_aliases = if other_names.len() == 1 { other_names } else { other_names[0..other_names.len() - 1] }
          if name in other_aliases {
            return Err(TicError.Resolve(f"name collision '{name}' between {other.term.names} and {entry.term.names}"))
          }
        }
      }
    }

    index += 1
  }

  var links: List[List[Int]] = []
  index = 0
  for entry in entries {
    var targets: List[Int] = []
    for wanted_name in entry.uses {
      let owners = by_name.get(wanted_name) ?? []
      var found = -1
      for owner in owners {
        if owner != index {
          found = owner
        }
      }

      guard found >= 0 else {
        return Err(TicError.Resolve(f"line {entry.line}: {first_name(entry.term.names)}: resolution of use={wanted_name} failed"))
      }

      targets += [found]
    }

    links += [targets]
    index += 1
  }

  # Merge in passes, as ncurses does: an entry merges once every entry it uses
  # has merged, so each merge sees fully resolved targets.
  var resolved: Map[Int, Term] = {}
  while resolved.len() < entries.len() {
    var progress = false
    for pending in range(entries.len()) {
      if pending in resolved {
        continue
      }

      let targets = links[pending]
      if ! [target for target in targets if target not in resolved].is_empty() {
        continue
      }

      resolved[pending] = merge_uses(entries[pending].term, [resolved[target] for target in targets])
      progress = true
    }

    guard progress else {
      let stuck = [first_name(entries[k].term.names) for k in range(entries.len()) if k not in resolved]
      return Err(TicError.Resolve(f"use= loop among {stuck.join(", ")}"))
    }
  }

  # fixup_acsc: an entry that switches character sets gets the VT100 map.
  var out: List[Term] = []
  index = 0
  while index < entries.len() {
    var term = resolved[index]
    let has_acsc = table.acsc in term.strs
    let smacs = text_of(term.strs.get(table.smacs) ?? Absent)
    let rmacs = text_of(term.strs.get(table.rmacs) ?? Absent)
    if ! has_acsc and smacs != null and rmacs != null {
      term = {...term, strs: term.strs.set(table.acsc, Text(bytes.from_text(VT_ACSC)))}
    }

    out += [term]
    index += 1
  }

  out
}

# tic's write-time rewrite of `%{n}` into the shorter `%'c'` for printable n.
proc shorten_constants(text: Bytes) -> Result[Bytes] {
  var out: List[Int] = []
  var t = 0
  let n = text.len()
  var changed = false
  while t < n {
    let ch = text.byte_at(t) ?? 0
    t += 1
    out += [ch]
    if ch == 92 {
      if t >= n {
        break
      }

      out += [text.byte_at(t) ?? 0]
      t += 1
    } else if ch == 37 and (text.byte_at(t) ?? 0) == 123 {
      let parsed = parse_c_long(text, t + 1)
      let end = if parsed.end == t + 1 { t + 1 } else { parsed.end }
      let value = parsed.value
      if (text.byte_at(end) ?? 0) == 125 and value > 0 and value != 92 and value < 127 and is_print(value) {
        out += [39, value, 39]
        t = end + 1
        changed = true
      }
    }
  }

  if ! changed {
    return text
  }

  bytes.from_ints(out)?
}

# Little-endian byte values of a 16- or 32-bit field; negative values are
# written in two's complement, as the C writer's unsigned conversion does.
pure le_ints(value: Int, width: Int) -> List[Int] {
  if width == 2 {
    let unsigned = if value < 0 { value + 65536 } else { value }
    [unsigned % 256, unsigned / 256 % 256]
  } else {
    let unsigned = if value < 0 { value + 4294967296 } else { value }
    [unsigned % 256, unsigned / 256 % 256, unsigned / 65536 % 256, unsigned / 16777216 % 256]
  }
}

pure le_fields(values: List[Int], width: Int) -> List[Int] {
  [byte for value in values for byte in le_ints(value, width)]
}

# compute_offsets: each string's offset in its table, -1 for absent and -2
# for cancelled.
stream string_offsets(values: List[StrCap]) -> Stream[Int] {
  var next = 0
  for value in values {
    match value {
      Absent => yield ABSENT_NUMERIC
      Cancelled => yield CANCELLED
      Text(text) => {
        yield next
        next += text.len() + 1
      }
    }
  }
}

stream name_offsets(names: List[Bytes]) -> Stream[Int] {
  var next = 0
  for name in names {
    yield next
    next += name.len() + 1
  }
}

pure string_table(values: List[StrCap]) -> List[Bytes] {
  [part for value in values for part in string_parts(value)]
}

pure string_parts(value: StrCap) -> List[Bytes] {
  match value {
    Text(text) => [text, b"\x00"]
    else => []
  }
}

pure table_size(parts: List[Bytes]) -> Int {
  var size = 0
  for part in parts {
    size += part.len()
  }

  size
}

# _nc_write_object: the compiled form of one resolved entry.
proc write_object(term: Term) -> Result[Bytes] {
  let names = bytes.from_text(term.names)
  guard names.len() <= MAX_NAME_SIZE else {
    return Err(TicError.Output(f"{first_name(term.names)}: name field longer than {MAX_NAME_SIZE} bytes"))
  }

  var boolmax = 0
  for {key, value} in term.bools {
    if value == TRUE_BOOLEAN and key + 1 > boolmax {
      boolmax = key + 1
    }
  }

  var nummax = 0
  var wide = false
  for {key, value} in term.nums {
    if key + 1 > nummax {
      nummax = key + 1
    }

    if value > MAX_SHORT {
      wide = true
    }
  }

  var strmax = 0
  for key in term.strs.keys() {
    if key + 1 > strmax {
      strmax = key + 1
    }
  }

  let width = if wide { 4 } else { 2 }
  let values = [term.strs.get(i) ?? Absent for i in range(strmax)]
  let offsets = string_offsets(values).collect()
  let strings = string_table(values)
  let nextfree = table_size(strings)
  let header = le_fields([if wide { MAGIC2 } else { MAGIC }, names.len() + 1, boolmax, nummax, strmax, nextfree], 2)
  let flags = [if (term.bools.get(i) ?? FALSE_BOOLEAN) == TRUE_BOOLEAN { 1 } else { 0 } for i in range(boolmax)]
  let pad = if (names.len() + 1 + boolmax) % 2 != 0 { [0] } else { [] }
  let nums = le_fields([term.nums.get(i) ?? ABSENT_NUMERIC for i in range(nummax)], width)
  let standard = [
    bytes.from_ints(header)?,
    names,
    b"\x00",
    bytes.from_ints(flags + pad + nums + le_fields(offsets, 2))?,
  ] + strings

  let ext = term.ext
  let extended = TRUE_BOOLEAN in ext.bools or ! [value for value in ext.nums if value != ABSENT_NUMERIC].is_empty() or ! [
    value
    for value in ext.strs
    if ! is_absent(value)
  ].is_empty()

  var parts = standard
  if extended {
    let ext_strings = string_table(ext.strs)
    let encoded_names = [bytes.from_text(name) for name in ext.names]
    # Name offsets restart at zero, relative to the first name.
    let ext_offsets = string_offsets(ext.strs).collect() + name_offsets(encoded_names).collect()
    let valid = [value for value in ext.strs if text_of(value) != null].len()
    let ext_size = table_size(ext_strings) + table_size([name for name in encoded_names]) + encoded_names.len()
    let lead = if nextfree % 2 != 0 { [0] } else { [] }
    let ext_header = le_fields([ext.nb, ext.nn, ext.ns, ext_count(ext) + valid, ext_size], 2)
    # Extended booleans are written as stored, so a cancelled one is 0376.
    let ext_flags = [(value + 256) % 256 for value in ext.bools]
    let ext_pad = if ext.nb % 2 != 0 { [0] } else { [] }
    let ext_fields = lead + ext_header + ext_flags + ext_pad + le_fields(ext.nums, width) + le_fields(ext_offsets, 2)
    parts = standard + [bytes.from_ints(ext_fields)?] + ext_strings + [
      part
      for name in encoded_names
      for part in [name, b"\x00"]
    ]
  }

  let object = bytes.concat(parts)
  guard object.len() <= MAX_ENTRY_SIZE else {
    return Err(TicError.Output(f"{first_name(term.names)}: entry is larger than {MAX_ENTRY_SIZE} bytes"))
  }

  object
}

proc write_entry(term: Term, outdir: Path) {
  var strs = term.strs
  for {key, value} in term.strs {
    match value {
      Text(text) => {
        let shorter = shorten_constants(text)?
        if shorter.len() < text.len() {
          strs[key] = Text(shorter)
        }
      }
      else => {}
    }
  }

  let object = write_object({...term, strs})?
  let names = entry_names(term.names)
  let primary = names[0]
  guard ! ("/" in primary) else {
    return Err(TicError.Output(f"{primary}: names may not contain a slash"))
  }

  let leaf = fp"{outdir}/{primary.byte_slice(0, 1)}"
  leaf.mkdir()
  let file = fp"{leaf}/{primary}"
  file.remove(missing_ok: true)
  file.write(object)

  if names.len() < 3 {
    return
  }

  for alias in names[1..names.len() - 1] {
    guard alias != "" else {
      return Err(TicError.Output(f"{primary}: empty alias in {term.names}"))
    }

    if "/" in alias {
      eprint f"tic: {primary}: cannot link alias {alias}."
      continue
    }

    if alias == primary {
      eprint f"tic: {primary}: self-synonym ignored"
      continue
    }

    let alias_leaf = fp"{outdir}/{alias.byte_slice(0, 1)}"
    alias_leaf.mkdir()
    let link = fp"{alias_leaf}/{alias}"
    link.remove(missing_ok: true)
    file.hardlink(at: link)
  }
}

pure selected(names: Str, wanted: List[Str]) -> Bool {
  if wanted.is_empty() {
    return true
  }

  let have = entry_names(names)
  for name in wanted {
    if name in have {
      return true
    }
  }

  false
}

proc compile(source: Path, outdir: Path, wanted: List[Str]) {
  let table = parse_cap_table(standard_caps_rows, ncurses_caps_rows)?
  let text = source.read_text()?
  let tokens = scan(text, table)
  let entries = parse_entries(tokens, table)?
  let terms = resolve(entries, table)?
  outdir.mkdir()
  for term in terms {
    if selected(term.names, wanted) {
      write_entry(term, outdir)
    }
  }
}

pure usage() -> Str {
  "usage: tic -x [-o DIR] [-e NAME[,NAME...]] FILE"
}

proc main(...argv: List[Str]) [fs, error] -> Result[Unit] {
  var extended = false
  var outdir: Path? = null
  var wanted: List[Str] = []
  var files: List[Str] = []
  var k = 0
  while k < argv.len() {
    let arg = argv[k]
    k += 1
    if arg == "-x" {
      extended = true
    } else if arg == "-o" or arg == "-e" {
      guard k < argv.len() else {
        return Err(TicError.Usage(f"{arg} needs a value; {usage()}"))
      }

      let value = argv[k]
      k += 1
      if arg == "-o" {
        outdir = Path(value)
      } else {
        wanted = wanted + [name.trim() for name in value.split(",") if name.trim() != ""]
      }
    } else if arg.starts_with("-") and arg != "-" {
      return Err(TicError.Usage(f"unsupported option {arg}; {usage()}"))
    } else {
      files += [arg]
    }
  }

  guard extended else {
    return Err(TicError.Usage(f"only extended-name compilation (-x) is implemented; {usage()}"))
  }

  guard files.len() == 1 else {
    return Err(TicError.Usage(usage()))
  }

  guard outdir != null else {
    return Err(TicError.Usage(f"an output directory (-o) is required; {usage()}"))
  }

  compile(Path(files[0]), outdir, wanted)
}
