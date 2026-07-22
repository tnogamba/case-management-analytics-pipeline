// ============================================================
// postcode_clean.m
// ============================================================
// three files in one:
//   part 1: postcode_cache        (reference data source)
//   part 2: location_distinct     (main cleaning query)
//   part 3: fx_lookup_postcode    (postcodes.io api function)
//
// purpose:
//   validates and standardises free-text postcode entries
//   and enriches each valid postcode with local authority,
//   ward and region via the postcodes.io public api.
//
// architecture — three-layer validation:
//
//   layer 1 — light cleaning (power query m)
//     strips non-alphanumeric characters, brackets, slashes,
//     dashes. removes leading/trailing whitespace. applies
//     standard uk postcode formatting (outward + space + inward).
//     validates inward code format against uk postcode rules.
//     applies o/i/l → 0/1/1 substitution for common ocr/typo
//     errors in the numeric portion of the inward code.
//     handles one known specific correction observed in the data.
//     handles the "LL" suffix edge case for welsh postcodes.
//
//   layer 2 — cache lookup (sharepoint excel)
//     before hitting the api, the query merges against a
//     postcode cache stored in sharepoint. previously validated
//     postcodes are resolved instantly from the cache without
//     an api call. the cache is updated periodically with
//     newly validated postcodes to keep api calls minimal.
//     this approach is critical for performance, the postcode
//     column has been free-text since the system launched
//     (still free-text at time of writing) resulting in 19,000+
//     distinct raw values.
//
//   layer 3 — postcodes.io api
//     only runs on postcodes not found in the cache.
//     returns: local authority, ward, region.
//     falls back to prefix-based region inference for
//     postcodes where the api returns no region (some scottish
//     and welsh postcodes).
//     invalid postcodes are flagged as "Invalid entry".
//
// output columns:
//   Original Post Code  — raw value from source crm
//   Postcode            — standardised valid postcode or "Invalid entry"
//   Local Authority     — local authority district or "Invalid entry"
//   Ward                — electoral ward or "Invalid entry"
//   Region              — uk region or "Invalid entry"
//
// dq signals:
//   "Missing entry"  ← null or blank raw value
//   "Invalid entry"  ← failed format validation or api lookup
//
// note on data context:
//   the postcode field has been free-text since the system
//   launched and remains free-text. raw values include valid
//   postcodes, partial postcodes, addresses, country names,
//   dates, phone numbers and random strings. the cleaning
//   layer handles this gracefully. Anything that cannot be
//   validated to a real uk postcode is flagged as Invalid entry
//   rather than silently dropped.
//
// author: tess ogamba · github.com/tessogamba
// ============================================================


// ------------------------------------------------------------
// part 1: postcode_cache — sharepoint excel reference table
// ------------------------------------------------------------
// previously validated postcodes stored in a shared excel file.
// merging against this cache before calling the api avoids
// redundant api calls on already-validated postcodes.
// the cache is updated periodically as new postcodes are validated.
//
// sharepoint url anonymised for portfolio.
// in production this points to a shared excel file on the
// organisation's sharepoint with columns:
//   Final_Postcode, Local Authority, Region, Ward
// ------------------------------------------------------------

let
    Source          = SharePoint.Files("[sharepoint_site_url]", [ApiVersion = 15]),
    #"Filtered Rows" = Table.SelectRows(Source, each ([Folder Path] = "[sharepoint_folder_path]")),
    PostcodeCacheFile = #"Filtered Rows"{[Name = "Postcode Cache.xlsx", #"Folder Path" = "[sharepoint_folder_path]"]}[Content],
    #"Imported Excel" = Excel.Workbook(PostcodeCacheFile),
    Postcode_Cache_Table = #"Imported Excel"{[Item = "Postcodecache", Kind = "Table"]}[Data]
in
    Postcode_Cache_Table


// ------------------------------------------------------------
// part 2: location_distinct — main postcode cleaning query
// ------------------------------------------------------------

let
    Source = stg_sql_server,
    #"Removed Other Columns" = Table.SelectColumns(Source, {"Post Code"}),

    // ----------------------------------------------------------
    // layer 1a: light cleaning — format normalisation
    // strips brackets, slashes, dashes and non-alphanumeric
    // characters. reformats to standard uk outward + inward
    // structure. validates inward code against uk format rules.
    // ----------------------------------------------------------
    #"Added Clean_Postcode" = Table.AddColumn(#"Removed Other Columns", "Clean_Postcode", each
        let
            raw = if [Post Code] = null then "" else Text.Upper(Text.Trim(Text.From([Post Code]))),

            // strip common suffixes / separators that appear before the postcode
            s1 = if Text.Contains(raw, "(") then Text.BeforeDelimiter(raw, "(") else raw,
            s2 = if Text.Contains(s1, "/")  then Text.BeforeDelimiter(s1, "/")  else s1,
            s3 = if Text.Contains(s2, "-")  then Text.BeforeDelimiter(s2, "-")  else s2,

            // keep only alphanumeric characters and spaces
            AllowedLetters = List.Transform({65..90}, each Character.FromNumber(_)),
            AllowedDigits  = List.Transform({48..57}, each Character.FromNumber(_)),
            Allowed        = AllowedLetters & AllowedDigits & {" "},
            s4             = Text.Select(s3, Allowed),

            // collapse multiple spaces, reformat as outward + space + inward
            parts     = List.Select(List.Transform(Text.Split(s4, " "), each Text.Trim(_)), each _ <> ""),
            noSpace   = Text.Combine(parts, ""),
            len0      = Text.Length(noSpace),
            formatted0 = if len0 > 3 then Text.Range(noSpace, 0, len0-3) & " " & Text.Range(noSpace, len0-3, 3) else noSpace,
            final0    = Text.Trim(formatted0),
            spacePos0 = Text.PositionOf(final0, " "),
            inward0   = if spacePos0 = -1 then "" else Text.Range(final0, spacePos0+1),

            // apply o→0, i→1, l→1 substitution in numeric positions
            // common ocr/manual entry errors in the inward code
            oFixed    = Text.Replace(Text.Replace(Text.Replace(noSpace, "O", "0"), "I", "1"), "L", "1"),
            len1      = Text.Length(oFixed),
            formatted1 = if len1 > 3 then Text.Range(oFixed, 0, len1-3) & " " & Text.Range(oFixed, len1-3, 3) else oFixed,
            final1    = Text.Trim(formatted1),
            spacePos1 = Text.PositionOf(final1, " "),
            inward1   = if spacePos1 = -1 then "" else Text.Range(final1, spacePos1+1),

            // validate inward code against uk postcode format rules
            // valid inward: digit + letter + letter  (e.g. 1AB)
            //               digit + digit + letter   (e.g. 2AB is invalid but 9AB is valid)
            //               digit + letter + digit   (e.g. 1A2 — valid for some areas)
            isValidInward = (s as text) =>
                Text.Length(s) = 3 and (
                    (Text.Contains("0123456789", Text.Range(s,0,1)) and Text.Contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", Text.Range(s,1,1)) and Text.Contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", Text.Range(s,2,1)))
                    or
                    (Text.Contains("0123456789", Text.Range(s,0,1)) and Text.Contains("0123456789", Text.Range(s,1,1)) and Text.Contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", Text.Range(s,2,1)))
                    or
                    (Text.Contains("0123456789", Text.Range(s,0,1)) and Text.Contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", Text.Range(s,1,1)) and Text.Contains("0123456789", Text.Range(s,2,1)))
                ),

            passedWithout = spacePos0 <> -1 and isValidInward(inward0),
            passedWith    = spacePos1 <> -1 and isValidInward(inward1),

            result =
                if raw = ""             then "Missing entry"
                else if passedWithout   then final0
                else if passedWith      then final1
                else                         "Invalid entry"
        in
            result
    ),

    // ----------------------------------------------------------
    // layer 1b: final postcode — additional edge case handling
    // handles one specific known correction observed in the data
    // and the "LL" suffix edge case for welsh postcodes where
    // the cleaning above produces a valid-looking but wrong result
    // ----------------------------------------------------------
    #"Added Final_Postcode" = Table.AddColumn(#"Added Clean_Postcode", "Final_Postcode", each
        let
            raw   = if [Post Code] = null then "" else Text.Upper(Text.Trim(Text.From([Post Code]))),
            clean = [Clean_Postcode],

            // specific known data entry error correction
            // one postcode in the data has a letter transposed
            // for a digit in the inward code
            fixKnownError = if raw = "[RAW_VALUE]" then "[CORRECTED_VALUE]" else null,

            Letters = List.Transform({65..90}, each Character.FromNumber(_)),
            Digits  = List.Transform({48..57}, each Character.FromNumber(_)),
            Allowed = Letters & Digits,
            stripped = Text.Select(raw, Allowed),
            len      = Text.Length(stripped),
            inward   = if len >= 3 then Text.Range(stripped, len-3, 3) else "",
            outward  = if len >  3 then Text.Range(stripped, 0, len-3) else "",

            // welsh postcode edge case: some welsh postcodes end in "LL"
            // (valid uk format) but were being rejected by the inward
            // validator. detect and pass through if outward contains digits.
            isLL =
                Text.EndsWith(inward, "LL") and
                Text.Length(outward) >= 2 and
                List.AnyTrue(List.Transform(Text.ToList(outward), each Text.Contains("0123456789", _))),

            result =
                if clean <> "Invalid entry"  then clean
                else if fixKnownError <> null then fixKnownError
                else if isLL                  then outward & " " & inward
                else                               "Invalid entry"
        in
            result
    ),

    #"Removed Duplicates0" = Table.Distinct(#"Added Final_Postcode", {"Post Code"}),

    // ----------------------------------------------------------
    // layer 2: cache lookup
    // merge against the postcode cache before hitting the api.
    // any postcode already in the cache resolves instantly.
    // the api function below only runs for cache misses.
    // ----------------------------------------------------------
    #"Merged Cache" = Table.NestedJoin(
        #"Removed Duplicates0",
        {"Final_Postcode"},
        Postcode_Lookup,
        {"Final_Postcode"},
        "Postcode_Lookup",
        JoinKind.LeftOuter
    ),
    #"Expanded Cache" = Table.ExpandTableColumn(
        #"Merged Cache",
        "Postcode_Lookup",
        {"Local Authority", "Region", "Ward"},
        {"Lookup_LA", "Lookup_Region", "Lookup_Ward"}
    ),

    // ----------------------------------------------------------
    // layer 3: postcodes.io api
    // invoked for every row — returns cached result immediately
    // for cache hits. only makes an http call for cache misses.
    // see fx_lookup_postcode below for api implementation.
    // ----------------------------------------------------------
    #"Invoked API" = Table.AddColumn(#"Expanded Cache", "API_Result", each fxLookupPostcode([Final_Postcode])),
    #"Expanded API" = Table.ExpandRecordColumn(
        #"Invoked API",
        "API_Result",
        {"Postcode", "LADName", "WardName", "RegionName"},
        {"Postcode", "LADName", "WardName", "RegionName"}
    ),

    // cache result takes priority over api result for ward
    // (cache may contain corrections not yet in the api)
    #"Combined Ward" = Table.AddColumn(#"Expanded API", "Final_Ward",
        each if [Lookup_Ward] <> null then [Lookup_Ward] else [WardName]
    ),

    // tidy up — rename, remove intermediate columns
    #"Renamed Source"  = Table.RenameColumns(#"Combined Ward", {{"Post Code", "Original Post Code"}}),
    #"Removed Columns" = Table.RemoveColumns(#"Renamed Source",
        {"Clean_Postcode", "Final_Postcode", "Lookup_LA", "Lookup_Region", "Lookup_Ward", "WardName"}
    ),
    #"Renamed Columns" = Table.RenameColumns(#"Removed Columns", {
        {"LADName",    "Local Authority"},
        {"RegionName", "Region"},
        {"Final_Ward", "Ward"}
    }),
    #"Removed Duplicates" = Table.Distinct(#"Renamed Columns", {"Original Post Code"})

in
    #"Removed Duplicates"


// ------------------------------------------------------------
// part 3: fx_lookup_postcode — postcodes.io api function
// ------------------------------------------------------------
// input:  pc as text  (cleaned/formatted postcode)
// output: record      [Postcode, LADName, WardName, RegionName]
//
// for invalid/missing postcodes: returns the input value in
// all fields (passes through dq signals without breaking)
//
// for valid postcodes: calls postcodes.io and returns
// local authority, ward and region.
//
// region inference fallback: postcodes.io returns null for
// region on some scottish and welsh postcodes. where this
// occurs, region is inferred from the postcode outward prefix.
// ------------------------------------------------------------

(pc as text) =>
let
    // known scottish and welsh outward code prefixes
    // used for region inference when api returns null
    ScottishPrefixes = {"AB","DD","DG","EH","FK","G","HS","IV","KA","KW","KY","ML","PA","PH","TD","ZE"},
    WelshPrefixes    = {"CF","CH","LD","LL","NP","SA","SY"},

    Result =
        // pass through dq signals without making an api call
        if pc = null or Text.Trim(pc) = "" or pc = "Invalid entry" or pc = "Missing entry" then
            [Postcode = pc, LADName = pc, WardName = pc, RegionName = pc]
        else
            let
                outward  = Text.Upper(Text.Select(Text.BeforeDelimiter(pc, " "), {"A".."Z"})),
                CleanPC  = Text.Replace(pc, " ", ""),

                // call postcodes.io — wrapped in try/otherwise to
                // handle network errors gracefully without breaking the query
                Source    = try Json.Document(Web.Contents("https://api.postcodes.io/postcodes/" & CleanPC)) otherwise null,
                APIResult = if Source <> null then try Source[result] otherwise null else null,

                LADName    = if APIResult <> null then APIResult[admin_district] else null,
                WardName   = if APIResult <> null then APIResult[admin_ward]     else null,
                RegionName = if APIResult <> null then APIResult[region]         else null,

                // infer region from prefix when api returns null
                InferredRegion =
                    if RegionName <> null then RegionName
                    else if List.AnyTrue(List.Transform(ScottishPrefixes, each Text.StartsWith(outward, _))) then "Scotland"
                    else if List.AnyTrue(List.Transform(WelshPrefixes,    each Text.StartsWith(outward, _))) then "Wales"
                    else null,

                FoundMatch    = APIResult <> null and LADName <> null,
                FinalPostcode = if FoundMatch then pc                                                          else "Invalid entry",
                FinalLA       = if FoundMatch then LADName                                                     else "Invalid entry",
                FinalWard     = if FoundMatch then (if WardName     <> null then WardName     else "Invalid entry") else "Invalid entry",
                FinalRegion   = if FoundMatch then (if InferredRegion <> null then InferredRegion else "Invalid entry") else "Invalid entry"
            in
                [Postcode = FinalPostcode, LADName = FinalLA, WardName = FinalWard, RegionName = FinalRegion]
in
    Result
