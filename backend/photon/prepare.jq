# Run on each line of the Photon dump before it is loaded (jq -c).
#
# Arabic and Kurdish write some letters several ways (أربيل / اربيل,
# مستشفى / مستشفي, ک / ك, ە / ه...), and people type them however their
# keyboard does. This adds the simplified spelling of a place's Arabic-script
# names to a name field the place doesn't use (reg_name, loc_name, old_name or
# int_name), which search reads but never shows. The API simplifies what people
# type the same way (normalizeQuery in src/services/geo.ts): keep both in step.

def simplify:
  gsub("[ً-ْٰـ]"; "")   # harakat, tatweel
  | gsub("[أإآٱ]"; "ا")
  | gsub("[ةەەھ]"; "ه")
  | gsub("[ىيیێې]"; "ي")
  | gsub("ک"; "ك")
  | gsub("ۆ"; "و")
  | gsub("ڵ"; "ل")
  | gsub("ڕ"; "ر");

def arabic_script: type == "string" and test("[؀-ۿ]");

if .type == "Place" then
  .content |= map(
    if (.name | type) == "object" then
      .name as $n
      | ([$n["name"], $n["name:ar"], $n["name:ckb"], $n["name:ku"], $n["alt_name"]]
          | map(select(arabic_script))) as $names
      | ([$names[] | simplify] | unique | map(select(. as $s | $names | index($s) | not))) as $simple
      | (["reg_name", "loc_name", "old_name", "int_name"] | map(select($n[.] == null)) | first) as $slot
      | if ($simple | length) > 0 and $slot != null
        then .name[$slot] = ($simple | join(" "))
        else . end
    else . end)
else . end
