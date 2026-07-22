// ============================================================
// employment_status_clean.m
// ============================================================
// purpose:
//   maps raw employment status entries to a controlled list
//   of 5 standardised values matching the organisation's
//   current employment status dropdown.
//
// controlled output values:
//   Employed
//   Job Seeker
//   Not Allowed To Work
//   Student
//   Unavailable For Work
//   Missing entry   ← dq signal: field was blank at source
//   Invalid entry   ← dq signal: value entered but unclassifiable
//   null            ← new variant not yet mapped (surfaces for review)
//
// approach:
//   same pattern as nationality — controlled list merged first,
//   custom column handles unmatched remainder.
//   the employment status field was free-text for several years
//   before a dropdown was introduced, resulting in a wide range
//   of variants including:
//     - unemployment typos (12+ spelling variants)
//     - wrong-field entries (website urls, names, council names)
//     - ambiguous fragments ("no", "f", "u", "2", "3")
//     - partial entries ("no se", "not e", "not ee")
//
// design decisions:
//   - "none" treated as Missing entry (system gap, not a refusal)
//   - "retired" → Unavailable For Work (no retired option exists)
//   - "private" → Employed (private sector employment)
//   - "un" → Job Seeker (consistent with "un employed" pattern)
//   - explicit noise list for wrong-field entries → Invalid entry
//   - genuine new variants fall through to null for review
//
// author: tess ogamba · github.com/tessogamba
// ============================================================


let
    Source                  = stg_sql_server,
    #"Removed Other Columns" = Table.SelectColumns(Source, {"Employment Status"}),
    #"Removed Duplicates"   = Table.Distinct(#"Removed Other Columns"),
    #"Renamed Columns"      = Table.RenameColumns(#"Removed Duplicates", {{"Employment Status", "employment_status_raw"}}),

    // ----------------------------------------------------------
    // step 1: merge against the crm controlled employment list
    // exact matches to the controlled list resolve immediately.
    // ----------------------------------------------------------
    #"Merged Queries" = Table.NestedJoin(
        #"Renamed Columns",
        {"employment_status_raw"},
        #"Employment status",
        {"lup_employment_status"},
        "ControlledEmploymentStatus",
        JoinKind.LeftOuter
    ),
    #"Expanded ControlledEmploymentStatus" = Table.ExpandTableColumn(
        #"Merged Queries",
        "ControlledEmploymentStatus",
        {"lup_employment_status"},
        {"lup_employment_status"}
    ),

    // ----------------------------------------------------------
    // step 2: custom column — map unmatched variants
    // controlled list match wins. unmatched variants are
    // classified by pattern matching below.
    // ----------------------------------------------------------
    #"Added Custom" = Table.AddColumn(
        #"Expanded ControlledEmploymentStatus",
        "Clean_EmploymentStatus",
        each
        let
            // normalise raw value
            v0      = if [employment_status_raw] = null then null else Text.From([employment_status_raw]),
            v       = if v0 = null then null else Text.Lower(Text.Trim(Text.Clean(v0))),
            isBlank = (v = null or v = ""),

            mapped =
                // blank or literal "none" → missing entry
                if isBlank or v = "none" then "Missing entry"

                // specific mappings not in controlled list
                else if v = "no permission to work" then "Not Allowed To Work"
                else if v = "not seeking work"       then "Unavailable For Work"

                // unemployment variants — 12+ spelling errors observed
                // result of free-text entry before dropdown was introduced
                else if List.Contains({
                    "unemployed", "uemployed", "unemplyed", "unemployment", "unemployer",
                    "long term unemployed", "long-term unemployed", "longterm unemployed",
                    "unemolyed", "unemloyed", "long term unemplyed", "un", "umemployed",
                    "unempoyed", "unempolyed", "unrmployed", "unemplopyed", "un employed",
                    "unemploued", "umrmployed"
                }, v) then "Job Seeker"

                // employed variants
                else if v = "self employed" or v = "self-employed" or v = "selfemployed"
                     or v = "employed"      or v = "private"       then "Employed"

                // unavailable variants (no direct match in controlled list)
                else if v = "retired"                                            then "Unavailable For Work"
                else if v = "other" or v = "no work status" or v = "career"     then "Unavailable For Work"

                // explicit noise — wrong-field entries, fragments, numbers
                // these are unclassifiable and confirmed not to be employment statuses
                else if List.Contains({
                    "niot", "3", "2", "f", "gov.uk", "internet", "eun", "u", "cab",
                    "friend", "no perfriend", "i", "not e", "not ee", "no", "no se"
                }, v) then "Invalid entry"

                // genuinely new unknown variant — surfaces as null for review
                else null
        in
            // controlled list match always wins over custom mapping
            if [lup_employment_status] <> null then [lup_employment_status] else mapped
    ),

    #"Renamed Columns1" = Table.RenameColumns(#"Added Custom", {{"Clean_EmploymentStatus", "clean_employment_status"}})

in
    #"Renamed Columns1"
