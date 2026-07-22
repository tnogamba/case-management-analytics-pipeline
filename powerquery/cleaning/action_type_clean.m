// ============================================================
// action_type_clean.m
// ============================================================
// purpose:
//   maps 300+ raw action type entries to a controlled list
//   of 21 standardised values matching the organisation's
//   current action type dropdown.
//
// controlled output values (action channel/mechanism):
//   0800
//   Advice
//   Application submitted
//   Case Checking
//   Class/workshop
//   Client Care Letter (OISC)
//   Email
//   File Archived
//   File Destroyed
//   Home visit
//   Letter
//   Meeting with Professionals
//   Online enquiry
//   Outreach
//   Post collection
//   Preparation
//   Referral
//   Signpost
//   Telephone
//   Text message
//   Unattended/Unresponsive/Disengaged
//   Update
//   Missing entry  ← dq signal: field was blank at source
//   Invalid entry  ← dq signal: service topic, not a channel
//   null           ← new variant not yet mapped (surfaces for review)
//
// key design decision — channel vs topic distinction:
//   the action type field was introduced partway through the
//   system's lifetime. before the dropdown existed, caseworkers
//   used this field to record the SUBJECT of the action
//   (e.g. "Housing", "Benefits", "Immigration", "Debt") rather
//   than the MECHANISM (e.g. "Telephone", "Email", "Advice").
//
//   the controlled list exclusively captures mechanism/channel.
//   all 270+ subject/topic entries (Housing, Benefits, Debt,
//   Immigration, NASS, S4, Family Reunion, Food Bank etc. and
//   their typos) are therefore classified as Invalid entry —
//   they are not wrong per se, they just answered a different
//   question than the current field is designed to capture.
//
// notable mapping:
//   "Face to Face" → "Advice"
//   the stored database value "Face to Face" was renamed to
//   "Advice" in the front-end crm display without changing
//   the underlying stored value. this mapping corrects the
//   discrepancy so reporting shows the current display label.
//   "Face to Face" is the single most common action type in
//   the database with 200,000+ records.
//
// author: tess ogamba · github.com/tessogamba
// ============================================================


let
    Source                  = stg_sql_server,
    #"Removed Other Columns" = Table.SelectColumns(Source, {"Action Type"}),
    #"Removed Duplicates"   = Table.Distinct(#"Removed Other Columns"),
    #"Renamed Columns"      = Table.RenameColumns(#"Removed Duplicates", {{"Action Type", "action_type_raw"}}),

    // ----------------------------------------------------------
    // step 1: merge against the crm controlled action type list
    // exact matches to the controlled list resolve immediately.
    // ----------------------------------------------------------
    #"Merged Queries" = Table.NestedJoin(
        #"Renamed Columns",
        {"action_type_raw"},
        #"Action type",
        {"lup_action_type"},
        "Action type",
        JoinKind.LeftOuter
    ),
    #"Expanded Action type" = Table.ExpandTableColumn(
        #"Merged Queries",
        "Action type",
        {"lup_action_type"},
        {"lup_action_type"}
    ),

    // ----------------------------------------------------------
    // step 2: custom column — map unmatched variants
    // ----------------------------------------------------------
    #"Added Custom" = Table.AddColumn(
        #"Expanded Action type",
        "action_type_clean",
        each
        let
            raw     = [action_type_raw],
            fuzzy   = [lup_action_type],
            clean   = if raw = null then "" else Text.Lower(Text.Trim(Text.Clean(raw))),
            isBlank = (clean = ""),

            mapped =
                if isBlank then "Missing entry"
                else if fuzzy <> null then fuzzy

                // --------------------------------------------------
                // genuine action channel/mechanism matches
                // corrected to current front-end display text values
                // where the stored value differs from the display label
                // --------------------------------------------------

                // stored "Face to Face" → display "Advice"
                // the front-end label was changed without updating
                // the stored value. 200,000+ historical records
                // carry the old stored value.
                else if clean = "face to face"                          then "Advice"

                else if clean = "0800 enquiry"                          then "0800"
                else if clean = "application"                           then "Application submitted"
                else if clean = "archived"                              then "File Archived"
                else if clean = "case checking"                         then "Case Checking"
                else if clean = "class"                                 then "Class/workshop"
                else if clean = "client care letter (oisc)"             then "Client Care Letter (OISC)"
                else if clean = "email"                                 then "Email"
                else if clean = "file archived"                         then "File Archived"
                else if clean = "file destroyed"                        then "File Destroyed"
                else if clean = "home visit"                            then "Home visit"
                else if clean = "letter"                                then "Letter"
                else if clean = "meeting with professionals"            then "Meeting with Professionals"
                else if clean = "online enquiry"                        then "Online enquiry"
                else if clean = "outreach"                              then "Outreach"
                else if clean = "post collection"                       then "Post collection"
                else if clean = "preperation"                           then "Preparation"
                else if clean = "referral"                              then "Referral"
                else if clean = "signpost"                              then "Signpost"
                else if clean = "signposting"                           then "Signpost"
                else if clean = "singnpostt"                            then "Signpost"
                else if clean = "telephone"                             then "Telephone"
                else if clean = "text message"                          then "Text message"
                else if clean = "unattended/unresponsive/disengaged"    then "Unattended/Unresponsive/Disengaged"
                else if clean = "update"                                then "Update"

                // --------------------------------------------------
                // service topics — not valid action types
                // these entries record WHAT the action was about
                // rather than HOW it was delivered.
                // they predate the introduction of the action type
                // dropdown and reflect a different understanding
                // of what the field was for.
                // all classified as Invalid entry.
                // --------------------------------------------------
                else if List.Contains({
                    // immigration / legal
                    "immigration", "immigration  advice", "immigration furtehr submission",
                    "lmmmgration", "immm", "imn", "imi", "imration", "immigrn", "immigratio",
                    "further submissionn unit immmigration", "legal", "legall", "lega", "lega;",
                    "legall", "l", "solicitors", "enquiring about citizenship", "citizenship",
                    "asylum", "asylum support", "s4", "s.4", "sec4", "s44", "s55", "s95",
                    "s 955", "s4`", "section 4", "nass", "nass1", "nass 2006", "nac",
                    "nac2006", "nac20006", "nacc", "nacc20066", "nac20066", "nac 2006",
                    "cpr54", "cnat", "tribunal", "triibunal", "repatriation", "repatiation",
                    "destitution", "iom", "ukb",
                    // benefits / welfare
                    "benefits", "benefit", "benefitbe", "child benefit", "child tax credit",
                    "universal credit", "esa", "jsa", "jobss", "tax", "taxes", "taxess",
                    "tax creditt", "council tax", "debt", "debts", "debet", "debtt", "deb",
                    "maternity grant", "matrenitygrant", "pregnancy", "pregnancy/antenatal",
                    "postage", "loan", "court fine",
                    // housing
                    "housing", "housig", "hosuing", "houi", "houy", "houd", "hos",
                    "rough sleeper", "rough sleepers",
                    // employment
                    "employment", "emplyment", "employmn", "eploymennt", "emoplooymment",
                    "emploument", "emplou", "employment.", "emply", "empo", "emp", "employmen",
                    "employment gained", "mploymentt", "e,mployment",
                    // health
                    "health", "health screening", "health, education", "mental health",
                    "addiction", "healht", "heah", "healnyasum", "heath", "helth", "hel",
                    "hed", "hew", "gp", "gpp", "nhs",
                    // food / utilities
                    "food bank", "food bankk", "food bankl", "food  bank", "food parcel",
                    "foodbank", "foodbankk", "foodd bankk", "foood baankk",
                    "utilities", "utility", "utilityy", "utillity", "utillities",
                    "utilies", "utilitis", "utilites", "utiliti", "utiliy", "utilitiess",
                    "utilitiies", "utilitieis", "utiilities", "utiilitiess", "utiilitis",
                    "utitlities", "utititiess", "utiliities", "utiliitiess", "uilities",
                    "utilitis", "utlities", "utilityy",
                    // family / relationships
                    "family support", "family reunion", "family su", "family sy", "family supo",
                    "family suppot", "famil reunion", "fanilr reunion", "fmaily re-unionn",
                    "familysupport", "familly suupport", "famifly support", "famly supp",
                    "famil reunion", "dfamily sup", "family support reunion",
                    // travel / dvla
                    "travel", "travell", "dvla",
                    // miscellaneous service topics
                    "education", "eucationn", "misc", "other", "others", "addiction",
                    "mental health", "saffron", "hsbc", "iom", "vp", "vpp", "dwp",
                    "dpa", "dp", "dpg", "dpe", "dph", "dpf", "dfp", "dp[", "ddp", "dps",
                    "hdf", "hdff", "hg",
                    // fragments and noise
                    "g", "k", "b", "f", "i", "l", "ii", "io", "in", "iq",
                    "eu", "ec", "ce", "cf", "se", "sd", "sr", "ms", "nm", "om",
                    "hu", "hew", "bew", "ber", "bn", "b1", "b]", "em,",
                    "i6", "i9", "i,", "oo", "pdf",
                    "i`````````````````````````````````````````````````",
                    "nino", "msc", "mic", "tdr112", "shadann", "fr",
                    "misd", "imo", "rmc", "council", "eu"
                }, clean) then "Invalid entry"

                // genuinely new unknown variant — surfaces as null for review
                else null
        in
            mapped
    ),

    #"Sorted Rows" = Table.Sort(#"Added Custom", {{"action_type_clean", Order.Ascending}})

in
    #"Sorted Rows"
