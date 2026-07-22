// ============================================================
// gender_clean.m
// ============================================================
// two files in one:
//   part 1: gender_distinct reference query
//   part 2: fx_gender_clean custom function
//
// purpose:
//   maps 200+ raw gender entries (years of free-text
//   entry before controlled lists were introduced) to a
//   set of 7 controlled output values matching the
//   organisation's current gender dropdown list.
//
// controlled output values:
//   Female (including trans woman)
//   Male (including trans man)
//   Non-binary
//   Other (not listed)
//   Prefer not to say
//   Missing entry   ← dq signal: field was blank at source
//   Invalid entry   ← dq signal: value entered but unclassifiable
//
// design decisions:
//   - trans entries handled with direction awareness:
//     "Transgender (She)" → Female (including trans woman)
//     "Transgender (He)"  → Male (including trans man)
//     bare "Transgender"  → Other (not listed)
//   - names entered in the gender field classified as Invalid
//   - address fragments, hotel names, email addresses
//     classified as Invalid (wrong-field data entry)
//   - "None", "Not captured" classified as Missing entry
//     (system gap) vs "Unspecified", "N/A" as Prefer not to say
//     (explicit non-disclosure — different dq meaning)
//   - clean controlled values (e.g. "Female (including trans woman)")
//     checked before the trans catch-all to prevent the word
//     "trans" inside a valid value triggering the wrong branch
//
// author: tess ogamba · github.com/tessogamba
// ============================================================


// ------------------------------------------------------------
// part 1: gender_distinct reference query
// ------------------------------------------------------------
// pulls all distinct raw gender values from the staging layer,
// invokes the cleaning function on each, and sorts by clean value.
// dim_client merges against this query on gender_raw to get
// the clean value without re-running the function per row.
// ------------------------------------------------------------

let
    Source                      = stg_sql_server,
    #"Removed Other Columns"    = Table.SelectColumns(Source, {"Gender"}),
    #"Renamed Columns"          = Table.RenameColumns(#"Removed Other Columns", {{"Gender", "gender_raw"}}),
    #"Removed Duplicates"       = Table.Distinct(#"Renamed Columns"),
    #"Invoked Custom Function"  = Table.AddColumn(#"Removed Duplicates", "gender_clean", each fx_GenderClean([gender_raw])),
    #"Sorted Rows"              = Table.Sort(#"Invoked Custom Function", {{"gender_clean", Order.Ascending}})
in
    #"Sorted Rows"


// ------------------------------------------------------------
// part 2: fx_gender_clean — custom cleaning function
// ------------------------------------------------------------
// input:  raw as nullable any  (raw value from source crm)
// output: nullable text        (controlled value or dq signal)
// ------------------------------------------------------------

(raw as nullable any) as nullable text =>

if raw = null then "Missing entry"
else

let
    _t0 = Text.From(raw),
    _t1 = Text.Clean(Text.Trim(_t0)),
    v0  = Text.Lower(_t1),

    // --------------------------------------------------------
    // detection flags
    // --------------------------------------------------------

    isEmpty = (v0 = ""),

    isNumber = try Value.Is(Value.FromText(v0), type number) otherwise false,

    // explicit non-disclosure — different from a blank field
    isPreferNotToSay =
        v0 = "n/a" or v0 = "na" or v0 = "n a" or
        v0 = "unspecified" or v0 = "not specified" or
        Text.Contains(v0, "prefer not"),

    // system/data gap — field was never completed
    isMissingNote =
        v0 = "none" or v0 = "not captured" or v0 = "not recorded",

    // punctuation-only tokens with no gender meaning
    isInvalidTokenOnly =
        v0 = "." or v0 = ".." or v0 = "-" or v0 = "," or v0 = "--" or
        v0 = "/" or v0 = "\" or v0 = "..." or v0 = "'",

    // address fragments, contact details, accommodation names
    // that appear in the gender field due to wrong-field entry
    looksAddressOrNumeric =
        isNumber or
        Text.Contains(v0, "flat")       or Text.Contains(v0, "room")     or
        Text.Contains(v0, "road")       or Text.Contains(v0, "waterloo") or
        Text.Contains(v0, "street")     or Text.Contains(v0, " st ")     or
        Text.EndsWith(v0, " st")        or Text.StartsWith(v0, "st ")    or
        Text.Contains(v0, " avenue")    or Text.Contains(v0, " ave")     or
        Text.Contains(v0, "hotel")      or Text.Contains(v0, "homeless") or
        Text.Contains(v0, "@"),

    // demographic/title values that do not represent gender
    isDefinitelyNoise =
        v0 = "english" or v0 = "indian" or v0 = "gender" or
        v0 = "mrs"     or v0 = "ms"     or v0 = "miss",

    // single letters with no unambiguous gender mapping
    isSingleLetterNoise =
        v0 = "w" or v0 = "o" or v0 = "r" or
        v0 = "a" or v0 = "b" or v0 = "g" or v0 = "t" or v0 = "n",

    // personal names entered in the gender field
    // (a subset of the full name list observed in the data)
    isKnownNameNoise =
        v0 = "f4"             or v0 = "muhammad"        or v0 = "radlinski"       or
        v0 = "patricia"       or v0 = "conrod"          or v0 = "bahram"          or
        v0 = "liyana"         or v0 = "audrey"          or v0 = "ezzuldin"        or
        v0 = "zahra"          or v0 = "malik"           or v0 = "omer gul"        or
        v0 = "najib"          or v0 = "michael"         or v0 = "amir"            or
        v0 = "mebrahmton"     or v0 = "adem"            or v0 = "marin"           or
        v0 = "mario"          or v0 = "vladyslaz"       or v0 = "allaalrahman"    or
        v0 = "shamsan"        or v0 = "fumilola roberta" or v0 = "mehdi"          or
        v0 = "ana"            or v0 = "massoud"         or v0 = "bernice",

    // strip punctuation for normalisation matching
    vPunctStripped = Text.Trim(Text.Remove(v0, {".", ",", ";", ":", "'", "`", "-", "_", "(", ")", "/", "\"})),

    // --------------------------------------------------------
    // direction-aware trans detection
    // checked before the generic trans catch-all
    // --------------------------------------------------------

    indicatesTransFemale =
        Text.Contains(vPunctStripped, "she")           or
        Text.Contains(vPunctStripped, "male to female") or
        Text.Contains(vPunctStripped, "mtf")           or
        Text.Contains(vPunctStripped, "trans woman")   or
        Text.Contains(vPunctStripped, "transwoman"),

    indicatesTransMale =
        Text.Contains(vPunctStripped, "he")            or
        Text.Contains(vPunctStripped, "female to male") or
        Text.Contains(vPunctStripped, "ftm")           or
        Text.Contains(vPunctStripped, "trans man")     or
        Text.Contains(vPunctStripped, "transman"),

    // --------------------------------------------------------
    // normalise female and male spelling variants
    // 40+ female typos, 20+ male typos observed in the data
    // (result of 5 years of free-text entry before dropdowns)
    // --------------------------------------------------------

    vNorm0 =
        if vPunctStripped = "femail"   or vPunctStripped = "femal"    or vPunctStripped = "femalle"
            or vPunctStripped = "femele"  or vPunctStripped = "femae"    or vPunctStripped = "femaale"
            or vPunctStripped = "feamle"  or vPunctStripped = "feale"    or vPunctStripped = "femnale"
            or vPunctStripped = "femaile" or vPunctStripped = "ffemale"  or vPunctStripped = "famale"
            or vPunctStripped = "fremale" or vPunctStripped = "frmale"   or vPunctStripped = "fe"
            or vPunctStripped = "fmale"   or vPunctStripped = "famle"    or vPunctStripped = "famele"
            or vPunctStripped = "fenale"  or vPunctStripped = "fenmale"  or vPunctStripped = "femalr"
            or vPunctStripped = "famel"   or vPunctStripped = "feamil"   or vPunctStripped = "fem"
            or vPunctStripped = "feml"    or vPunctStripped = "emale"    or vPunctStripped = "women"
            or vPunctStripped = "woman"   or vPunctStripped = "fale"     or vPunctStripped = "fenake"
            or vPunctStripped = "femakle" or vPunctStripped = "femle"    or vPunctStripped = "femali"
            or vPunctStripped = "ff"      or vPunctStripped = "femal3"   or vPunctStripped = "feminin"
            or vPunctStripped = "femanle" or vPunctStripped = "fema"     or vPunctStripped = "femaie"
            or vPunctStripped = "fermale" or vPunctStripped = "daughter"
        then "female"

        else if vPunctStripped = "mail"  or vPunctStripped = "mal"   or vPunctStripped = "maale"
            or vPunctStripped = "male"   or vPunctStripped = "maler" or vPunctStripped = "maled"
            or vPunctStripped = "make"   or vPunctStripped = "mle"   or vPunctStripped = "maile"
            or vPunctStripped = "malr"   or vPunctStripped = "nale"  or vPunctStripped = "mn"
            or vPunctStripped = "m?"     or vPunctStripped = "mr"    or vPunctStripped = "mlae"
            or vPunctStripped = "malle"  or vPunctStripped = "ma"    or vPunctStripped = "men"
            or vPunctStripped = "malw"
        then "male"

        else vPunctStripped,

    // --------------------------------------------------------
    // classification — order matters
    // --------------------------------------------------------

    result =
        if isEmpty                                                          then "Missing entry"
        else if isMissingNote                                               then "Missing entry"
        else if isPreferNotToSay                                            then "Prefer not to say"
        else if isInvalidTokenOnly or looksAddressOrNumeric
             or isDefinitelyNoise  or isSingleLetterNoise
             or isKnownNameNoise                                            then "Invalid entry"

        // exact matches on clean controlled values checked first —
        // prevents the word "trans" inside a valid value from
        // triggering the direction-aware trans catch-all below
        else if vPunctStripped = "female including trans woman"             then "Female (including trans woman)"
        else if vPunctStripped = "male including trans man"                 then "Male (including trans man)"
        else if vPunctStripped = "non binary"                               then "Non-binary"
        else if vPunctStripped = "other not listed"                         then "Other (not listed)"
        else if vPunctStripped = "prefer not to say"                        then "Prefer not to say"

        else if vNorm0 = "both"                                             then "Other (not listed)"
        else if vNorm0 = "other (not listed)" or vNorm0 = "other not listed"
             or vNorm0 = "other"                                            then "Other (not listed)"

        // direction-aware trans — checked before generic catch-all
        else if Text.Contains(vNorm0, "trans") and indicatesTransFemale     then "Female (including trans woman)"
        else if Text.Contains(vNorm0, "trans") and indicatesTransMale       then "Male (including trans man)"
        else if Text.Contains(vNorm0, "trans")                              then "Other (not listed)"

        else if Text.Contains(vNorm0, "nonbinary")
             or Text.Contains(vNorm0, "non-bin") or vNorm0 = "nb"           then "Non-binary"

        else if vNorm0 = "girl"                                             then "Female (including trans woman)"
        else if vNorm0 = "boy" or vNorm0 = "son"
             or Text.Contains(vNorm0, "nephew")                             then "Male (including trans man)"
        else if vNorm0 = "female" or vNorm0 = "woman"
             or Text.Contains(vNorm0, "female")                             then "Female (including trans woman)"
        else if vNorm0 = "male" or vNorm0 = "man"
             or Text.StartsWith(vNorm0, "male")                             then "Male (including trans man)"
        else if vNorm0 = "f"                                                then "Female (including trans woman)"
        else if vNorm0 = "m"                                                then "Male (including trans man)"

        // unknown variant — surfaces as null for review
        // indicates a new raw value not yet covered by this function
        else null

in
    result
