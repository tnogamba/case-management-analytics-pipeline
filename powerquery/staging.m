// ============================================================
// staging query — casework analytics pipeline
// ============================================================
// connects to the source crm database via native sql statement
// and applies structured cleaning to all text columns before
// downstream dimension and fact table queries consume it.
//
// sql query embedded below performs:
//   - eav pivot for client and case attribute tables
//   - household reference resolution via row_number()
//   - previous case owner concatenation via string_agg()
//   - window functions for last action date, enquiry time etc
//   - dual soft-delete filtering (datetime null pattern)
//
// power query steps applied after sql:
//   1. type coercion — dates, integers, text
//   2. staff name standardisation — text.proper() on all
//      staff columns to resolve case inconsistencies
//      (same caseworker stored as "john smith", "JOHN SMITH",
//       "john smith" across different entry points)
//   3. text.trim() — removes leading/trailing whitespace
//   4. text.clean() — removes non-printable characters
//   5. enquiry type normalisation — legacy value replaced
//      with current controlled value
//
// note: load is enabled on this query so the sql executes
// once per refresh and all downstream dims read from the
// cached result. disabling load causes the sql to re-execute
// once per downstream query which is significantly slower.
//
// data range: 2014 to present
// pre-2019 records migrated from legacy system — higher
// rates of missing/invalid entries expected in that period.
//
// author: tess ogamba · github.com/tessogamba
// ============================================================

let
    // ----------------------------------------------------------
    // step 1: connect to source database via native sql
    // server address and database name anonymised for portfolio
    // the full sql query is documented separately in:
    //   sql/core_query.sql
    // ----------------------------------------------------------
    Source = Sql.Database(
        "[server_address]",
        "[database_name]",
        [
            CommandTimeout = #duration(0, 0, 30, 0),
            Query = "
-- eav pivot, household resolution, window functions
-- see sql/core_query.sql for full annotated query
            ",
            CreateNavigationProperties = false
        ]
    ),

    // ----------------------------------------------------------
    // step 2: type coercion
    // dates parsed from varchar, integers for time columns,
    // all other columns default to text
    // ----------------------------------------------------------
    #"Changed Type" = Table.TransformColumnTypes(Source, {
        {"Client Reference",                    type text},
        {"Household Reference",                 type text},
        {"Is Main Client",                      type text},
        {"Client Added Date",                   type date},
        {"Client Added By",                     type text},
        {"Surname",                             type text},
        {"First Names",                         type text},
        {"Date of Birth",                       type date},
        {"Date of Arrival",                     type date},
        {"Enquiry Date",                        type date},
        {"Current Status Grant Date",           type date},
        {"Current Status Expiry Date",          type date},
        {"Enquiry Closed Date",                 type date},
        {"Action Date",                         type date},
        {"Action Time",                         Int64.Type},
        {"Action Deadline Date",                type date},
        {"Referral Date",                       type date},
        {"Signpost Date",                       type date},
        {"Last Action Date",                    type date},
        {"Latest Deadline Date",                type date},
        {"Enquiry Time",                        Int64.Type}
    }),

    // ----------------------------------------------------------
    // step 3: staff name standardisation — text.proper()
    // the crm stores caseworker names entered by different users
    // with inconsistent casing. text.proper() normalises all
    // staff columns so "john smith", "JOHN SMITH" and
    // "John Smith" all resolve to "John Smith" and match
    // correctly to dim_staff on the name key.
    // applied before trim/clean to avoid reintroducing issues.
    // ----------------------------------------------------------
    #"Proper Case Staff" = Table.TransformColumns(#"Changed Type", {
        {"Client Added By",     Text.Proper, type text},
        {"Enquiry Created By",  Text.Proper, type text},
        {"Enquiry Owner",       Text.Proper, type text},
        {"Enquiry Closed By",   Text.Proper, type text},
        {"Action By",           Text.Proper, type text}
    }),

    // ----------------------------------------------------------
    // step 4: text.trim() — removes leading/trailing whitespace
    // action time and enquiry time cast to text first to allow
    // trim/clean to run consistently across all columns
    // ----------------------------------------------------------
    #"Trimmed Text" = Table.TransformColumns(
        Table.TransformColumnTypes(
            #"Proper Case Staff",
            {{"Action Time", type text}, {"Enquiry Time", type text}},
            "en-GB"
        ),
        {
            {"Client Reference",                    Text.Trim, type text},
            {"Household Reference",                 Text.Trim, type text},
            {"Is Main Client",                      Text.Trim, type text},
            {"Client Added By",                     Text.Trim, type text},
            {"Surname",                             Text.Trim, type text},
            {"First Names",                         Text.Trim, type text},
            {"Nationality",                         Text.Trim, type text},
            {"Gender",                              Text.Trim, type text},
            {"Gender Assigned at Birth",            Text.Trim, type text},
            {"Ethnic Origin",                       Text.Trim, type text},
            {"Religion",                            Text.Trim, type text},
            {"Marital Status",                      Text.Trim, type text},
            {"Sexual Orientation",                  Text.Trim, type text},
            {"Disability",                          Text.Trim, type text},
            {"Spoken Language",                     Text.Trim, type text},
            {"English Proficiency",                 Text.Trim, type text},
            {"Employment Status",                   Text.Trim, type text},
            {"Housing Status",                      Text.Trim, type text},
            {"Housing Provider",                    Text.Trim, type text},
            {"Client Immigration Status",           Text.Trim, type text},
            {"Inbound Referral Agency",             Text.Trim, type text},
            {"Inbound Signpost Route",              Text.Trim, type text},
            {"Client Project Tag",                  Text.Trim, type text},
            {"Mobile Number",                       Text.Trim, type text},
            {"Email",                               Text.Trim, type text},
            {"House Number",                        Text.Trim, type text},
            {"Address Line 1",                      Text.Trim, type text},
            {"Address Line 2",                      Text.Trim, type text},
            {"Post Code",                           Text.Trim, type text},
            {"Town",                                Text.Trim, type text},
            {"Known As",                            Text.Trim, type text},
            {"NINO",                                Text.Trim, type text},
            {"HO Ref Number",                       Text.Trim, type text},
            {"NASS Ref Number",                     Text.Trim, type text},
            {"Next of Kin Name",                    Text.Trim, type text},
            {"Next of Kin Contact Number",          Text.Trim, type text},
            {"Enquiry Reference",                   Text.Trim, type text},
            {"Enquiry Created By",                  Text.Trim, type text},
            {"Enquiry Type",                        Text.Trim, type text},
            {"Enquiry Owner",                       Text.Trim, type text},
            {"Previous Owners",                     Text.Trim, type text},
            {"Enquiry Immigration Status",          Text.Trim, type text},
            {"Consent Type",                        Text.Trim, type text},
            {"Q1 Answer",                           Text.Trim, type text},
            {"Q2 Answer",                           Text.Trim, type text},
            {"Q3 Answer",                           Text.Trim, type text},
            {"Desired Outcome",                     Text.Trim, type text},
            {"Enquiry Info",                        Text.Trim, type text},
            {"Actual Outcome",                      Text.Trim, type text},
            {"Outcome Reason",                      Text.Trim, type text},
            {"Enquiry Closed By",                   Text.Trim, type text},
            {"Enquiry Project Tag",                 Text.Trim, type text},
            {"How did they hear about us?",         Text.Trim, type text},
            {"Referral/signposting source",         Text.Trim, type text},
            {"Vulnerabilities",                     Text.Trim, type text},
            {"Action By",                           Text.Trim, type text},
            {"Action Type",                         Text.Trim, type text},
            {"Action Time",                         Text.Trim, type text},
            {"Action Info",                         Text.Trim, type text},
            {"Referral Agency",                     Text.Trim, type text},
            {"Signpost Agency",                     Text.Trim, type text},
            {"Staff Access Level",                  Text.Trim, type text},
            {"Staff Site",                          Text.Trim, type text},
            {"Enquiry Time",                        Text.Trim, type text},
            {"Last Action Info",                    Text.Trim, type text}
        }
    ),

    // ----------------------------------------------------------
    // step 5: text.clean() removes non-printable characters
    // historical data migration introduced control characters
    // in some free-text fields. text.clean() strips these
    // before downstream cleaning functions run.
    // ----------------------------------------------------------
    #"Cleaned Text" = Table.TransformColumns(#"Trimmed Text", {
        {"Client Reference",                    Text.Clean, type text},
        {"Household Reference",                 Text.Clean, type text},
        {"Is Main Client",                      Text.Clean, type text},
        {"Client Added By",                     Text.Clean, type text},
        {"Surname",                             Text.Clean, type text},
        {"First Names",                         Text.Clean, type text},
        {"Nationality",                         Text.Clean, type text},
        {"Gender",                              Text.Clean, type text},
        {"Gender Assigned at Birth",            Text.Clean, type text},
        {"Ethnic Origin",                       Text.Clean, type text},
        {"Religion",                            Text.Clean, type text},
        {"Marital Status",                      Text.Clean, type text},
        {"Sexual Orientation",                  Text.Clean, type text},
        {"Disability",                          Text.Clean, type text},
        {"Spoken Language",                     Text.Clean, type text},
        {"English Proficiency",                 Text.Clean, type text},
        {"Employment Status",                   Text.Clean, type text},
        {"Housing Status",                      Text.Clean, type text},
        {"Housing Provider",                    Text.Clean, type text},
        {"Client Immigration Status",           Text.Clean, type text},
        {"Inbound Referral Agency",             Text.Clean, type text},
        {"Inbound Signpost Route",              Text.Clean, type text},
        {"Client Project Tag",                  Text.Clean, type text},
        {"Mobile Number",                       Text.Clean, type text},
        {"Email",                               Text.Clean, type text},
        {"House Number",                        Text.Clean, type text},
        {"Address Line 1",                      Text.Clean, type text},
        {"Address Line 2",                      Text.Clean, type text},
        {"Post Code",                           Text.Clean, type text},
        {"Town",                                Text.Clean, type text},
        {"Known As",                            Text.Clean, type text},
        {"NINO",                                Text.Clean, type text},
        {"HO Ref Number",                       Text.Clean, type text},
        {"NASS Ref Number",                     Text.Clean, type text},
        {"Next of Kin Name",                    Text.Clean, type text},
        {"Next of Kin Contact Number",          Text.Clean, type text},
        {"Enquiry Reference",                   Text.Clean, type text},
        {"Enquiry Created By",                  Text.Clean, type text},
        {"Enquiry Type",                        Text.Clean, type text},
        {"Enquiry Owner",                       Text.Clean, type text},
        {"Previous Owners",                     Text.Clean, type text},
        {"Enquiry Immigration Status",          Text.Clean, type text},
        {"Consent Type",                        Text.Clean, type text},
        {"Q1 Answer",                           Text.Clean, type text},
        {"Q2 Answer",                           Text.Clean, type text},
        {"Q3 Answer",                           Text.Clean, type text},
        {"Desired Outcome",                     Text.Clean, type text},
        {"Enquiry Info",                        Text.Clean, type text},
        {"Actual Outcome",                      Text.Clean, type text},
        {"Outcome Reason",                      Text.Clean, type text},
        {"Enquiry Closed By",                   Text.Clean, type text},
        {"Enquiry Project Tag",                 Text.Clean, type text},
        {"How did they hear about us?",         Text.Clean, type text},
        {"Referral/signposting source",         Text.Clean, type text},
        {"Vulnerabilities",                     Text.Clean, type text},
        {"Action By",                           Text.Clean, type text},
        {"Action Type",                         Text.Clean, type text},
        {"Action Time",                         Text.Clean, type text},
        {"Action Info",                         Text.Clean, type text},
        {"Referral Agency",                     Text.Clean, type text},
        {"Signpost Agency",                     Text.Clean, type text},
        {"Staff Access Level",                  Text.Clean, type text},
        {"Staff Site",                          Text.Clean, type text},
        {"Enquiry Time",                        Text.Clean, type text},
        {"Last Action Info",                    Text.Clean, type text}
    }),

    // ----------------------------------------------------------
    // step 6: enquiry type normalisation
    // a legacy value was renamed in the crm but historical
    // records still carry the old value. replaced here so
    // reporting shows a single consistent controlled value.
    // ----------------------------------------------------------
    #"Normalised Enquiry Type" = Table.ReplaceValue(
        #"Cleaned Text",
        "Legacy Value",
        "Current Value",
        Replacer.ReplaceText,
        {"Enquiry Type"}
    )

in
    #"Normalised Enquiry Type"
