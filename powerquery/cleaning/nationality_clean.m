// ============================================================
// nationality_clean.m
// ============================================================
// purpose:
//   maps 496+ raw nationality entries to a controlled list
//   of 228 standardised nationality values matching the
//   organisation's current nationality dropdown.
//
// approach:
//   unlike gender (which uses a reusable function), nationality
//   cleaning is implemented as a custom column directly on the
//   distinct reference query. this is because:
//     - the mapping is a large static lookup (496 entries)
//     - the lookup table (Nationality) from the crm is merged
//       first — any exact match to the controlled list wins
//     - the custom column only handles the unmatched remainder
//       (typos, country names used instead of demonyms,
//        abbreviations, iso codes, dual nationality entries)
//
// controlled output:
//   228 standardised nationality values from the crm dropdown
//   Missing entry  ← null or blank at source
//   Invalid entry  ← placeholder codes (ILR, XXA, XXB, etc.)
//   null           ← new variant not yet mapped (surfaces for review)
//
// data context:
//   nationality was a free-text field for several years before
//   a controlled dropdown was introduced. the 496 variants
//   reflect this history — the same nationality appears as the
//   country name ("Afghanistan"), the demonym ("Afghan"),
//   abbreviations ("AFG"), iso codes ("AFG"), dual entries
//   ("Afghan/British"), typos ("Afghani") and combinations.
//
//   some judgment calls in the mapping:
//     - "Kurdish" → Iraqi (most common nationality for Kurdish
//       clients in uk casework context; no Kurdish option exists)
//     - "Tibetan" → Stateless (no Tibetan nationality in crm list)
//     - "Congo" (bare) → Congolese (DRC) (more common in caseload
//       than Republic of Congo; both are valid options in the list)
//     - dual nationality entries → first-listed nationality
//     - "ILR", "XXA", "XXB" → Invalid entry (administrative codes
//       entered in the wrong field)
//
// author: tess ogamba · github.com/tessogamba
// ============================================================


let
    Source                          = stg_sql_server,
    #"Removed Other Columns"        = Table.SelectColumns(Source, {"Nationality"}),
    #"Renamed Columns"              = Table.RenameColumns(#"Removed Other Columns", {{"Nationality", "nationality_raw"}}),
    #"Removed Duplicates"           = Table.Distinct(#"Renamed Columns"),

    // ----------------------------------------------------------
    // step 1: merge against the crm controlled nationality list
    // any raw value that exactly matches a controlled value wins
    // immediately — no further mapping needed for those rows.
    // the custom column below only runs on unmatched rows.
    // ----------------------------------------------------------
    #"Merged Queries" = Table.NestedJoin(
        #"Removed Duplicates",
        {"nationality_raw"},
        Nationality,
        {"lup_nationality"},
        "ControlledNationality",
        JoinKind.LeftOuter
    ),
    #"Expanded ControlledNationality" = Table.ExpandTableColumn(
        #"Merged Queries",
        "ControlledNationality",
        {"lup_nationality"},
        {"lup_nationality"}
    ),

    // ----------------------------------------------------------
    // step 2: custom column — map unmatched variants
    // if the controlled list merge found a match, use it.
    // otherwise apply the variant mapping below.
    // null at the end means a genuinely new variant has appeared
    // in the data that is not yet covered — it will surface in
    // dq reporting for review and mapping in the next update.
    // ----------------------------------------------------------
    #"Added Custom" = Table.AddColumn(
        #"Expanded ControlledNationality",
        "clean_nationality",
        each let
            raw = [nationality_raw],
            v   = if raw = null then "" else Text.Lower(Text.Trim(Text.From(raw)))
        in
            if [lup_nationality] <> null then [lup_nationality] else
            if raw = null or v = "" then "Missing entry" else

            // country names used instead of demonyms
            if v = "afghanistan" then "Afghan" else
            if v = "albania" then "Albanian" else
            if v = "angola" then "Angolan" else
            if v = "burkina faso" then "Burkinan" else
            if v = "burma" then "Burmese" else
            if v = "cameroon" then "Cameroonian" else
            if v = "central african republic" then "Central African" else
            if v = "chad" then "Chadian" else
            if v = "china" then "Chinese" else
            if v = "denmark" then "Danish" else
            if v = "el salvador" then "Salvadorean" else
            if v = "elsalvador" then "Salvadorean" else
            if v = "germany" then "German" else
            if v = "india" then "Indian" else
            if v = "iran" then "Iranian" else
            if v = "iraq" then "Iraqi" else
            if v = "israel" then "Israeli" else
            if v = "italy" then "Italian" else
            if v = "jamaica" then "Jamaican" else
            if v = "kosovo" then "Kosovan" else
            if v = "kuwait" then "Kuwaiti" else
            if v = "malawi" then "Malawian" else
            if v = "mauritania" then "Mauritanian" else
            if v = "mauritius" then "Mauritian" else
            if v = "moldova" then "Moldovan" else
            if v = "montserrat" then "Montserratian" else
            if v = "morocco" then "Moroccan" else
            if v = "mozambique" then "Mozambican" else
            if v = "myanmar" then "Burmese" else
            if v = "nauru" then "Nauruan" else
            if v = "nepal" then "Nepalese" else
            if v = "north korea" then "North Korean" else
            if v = "norway" then "Norwegian" else
            if v = "pakistan" then "Pakistani" else
            if v = "palestine" then "Palestinian" else
            if v = "romania" then "Romanian" else
            if v = "russia" then "Russian" else
            if v = "rwanda" then "Rwandan" else
            if v = "senegal" then "Senegalese" else
            if v = "serbia" then "Serbian" else
            if v = "somalia" then "Somali" else
            if v = "south sudan" then "South Sudanese" else
            if v = "spain" then "Spanish" else
            if v = "sri lanka" then "Sri Lankan" else
            if v = "sudan" then "Sudanese" else
            if v = "syria" then "Syrian" else
            if v = "tanzania" then "Tanzanian" else
            if v = "thailand" then "Thai" else
            if v = "togo" then "Togolese" else
            if v = "trinidad" then "Trinidadian" else
            if v = "uganda" then "Ugandan" else
            if v = "ukraine" then "Ukrainian" else
            if v = "uruguay" then "Uruguayan" else
            if v = "usa" then "American" else
            if v = "zimbabwe" then "Zimbabwean" else

            // demonym typos and spelling variants
            if v = "afghani" then "Afghan" else
            if v = "alabanian" then "Albanian" else
            if v = "ausrtian" then "Austrian" else
            if v = "bangladehi" then "Bangladeshi" else
            if v = "belgians" then "Belgian" else
            if v = "belge" then "Belgian" else
            if v = "belorussian" then "Belarusian" else
            if v = "bengladehi" then "Bangladeshi" else
            if v = "bosnian" then "Citizen of Bosnia and Herzegovina" else
            if v = "brundian" then "Burundian" else
            if v = "burkinese" then "Burkinan" else
            if v = "cameronians" then "Cameroonian" else
            if v = "chechnyan" then "Russian" else
            if v = "chinesse" then "Chinese" else
            if v = "datch" then "Dutch" else
            if v = "ecuadorian" then "Ecuadorean" else
            if v = "egyptians" then "Egyptian" else
            if v = "eritean" then "Eritrean" else
            if v = "eriteran" then "Eritrean" else
            if v = "ertiean" then "Eritrean" else
            if v = "ethipioan" then "Ethiopian" else
            if v = "fhilippines" then "Filipino" else
            if v = "ghanian" then "Ghanaian" else
            if v = "inidan" then "Indian" else
            if v = "irana" then "Iranian" else
            if v = "iraqi/british" then "Iraqi" else
            if v = "iranian/ british" then "Iranian" else
            if v = "iraqq" then "Iraqi" else
            if v = "irqai" then "Iraqi" else
            if v = "italia" then "Italian" else
            if v = "ivoirian" then "Ivorian" else
            if v = "ivorienne" then "Ivorian" else
            if v = "ivory" then "Ivorian" else
            if v = "jamacian" then "Jamaican" else
            if v = "jamcian" then "Jamaican" else
            if v = "kenian" then "Kenyan" else
            if v = "kirghizistan" then "Kyrgyz" else
            if v = "latvian alien passport" then "Latvian" else
            if v = "lithuanian" then "Lithuanian" else
            if v = "lituanian" then "Lithuanian" else
            if v = "lybian" then "Libyan" else
            if v = "madagascan" then "Malagasy" else
            if v = "malawi-british" then "Malawian" else
            if v = "malienne" then "Malian" else
            if v = "maurtian" then "Mauritian" else
            if v = "maynmar" then "Burmese" else
            if v = "moldovan/romanian" then "Moldovan" else
            if v = "moroco" then "Moroccan" else
            if v = "motswana" then "Botswanan" else
            if v = "myanmarian" then "Burmese" else
            if v = "namebian" then "Namibian" else
            if v = "nederlanden" then "Dutch" else
            if v = "nederlandese" then "Dutch" else
            if v = "nederlandse" then "Dutch" else
            if v = "netherland" then "Dutch" else
            if v = "nepali" then "Nepalese" else
            if v = "nepalise" then "Nepalese" else
            if v = "nevisian" then "Kittitian" else
            if v = "new zeland" then "New Zealander" else
            if v = "newzeland" then "New Zealander" else
            if v = "nig" then "Nigerian" else
            if v = "nigeran" then "Nigerian" else
            if v = "nigerian-british" then "Nigerian" else
            if v = "nigerien-british" then "Nigerien" else
            if v = "nipal" then "Nepalese" else
            if v = "norwegian" then "Norwegian" else
            if v = "norwgian" then "Norwegian" else
            if v = "orc congo" then "Congolese (DRC)" else
            if v = "pakisatani" then "Pakistani" else
            if v = "pakisatn" then "Pakistani" else
            if v = "pakistani-british" then "Pakistani" else
            if v = "pakistanian" then "Pakistani" else
            if v = "paksitani" then "Pakistani" else
            if v = "pakstan" then "Pakistani" else
            if v = "pakstani" then "Pakistani" else
            if v = "pakstanian" then "Pakistani" else
            if v = "palastaine" then "Palestinian" else
            if v = "palastinain-polish" then "Palestinian" else
            if v = "palastinan" then "Palestinian" else
            if v = "palastine" then "Palestinian" else
            if v = "palastinian" then "Palestinian" else
            if v = "palestenian" then "Palestinian" else
            if v = "palestian" then "Palestinian" else
            if v = "palestinain" then "Palestinian" else
            if v = "palestinan" then "Palestinian" else
            if v = "palestnian" then "Palestinian" else
            if v = "philipino" then "Filipino" else
            if v = "philippine" then "Filipino" else
            if v = "phillipino" then "Filipino" else
            if v = "phlipinas" then "Filipino" else
            if v = "polish" then "Polish" else
            if v = "portugese" then "Portuguese" else
            if v = "republic of serbia" then "Serbian" else
            if v = "romaina" then "Romanian" else
            if v = "romainain" then "Romanian" else
            if v = "romainan" then "Romanian" else
            if v = "romainian" then "Romanian" else
            if v = "romanain" then "Romanian" else
            if v = "romaninan" then "Romanian" else
            if v = "roumania" then "Romanian" else
            if v = "roumanian" then "Romanian" else
            if v = "rusian" then "Russian" else
            if v = "saint kitts" then "Kittitian" else
            if v = "saint lucia" then "St Lucian" else
            if v = "saint lucian" then "St Lucian" else
            if v = "saint vincent" then "Vincentian" else
            if v = "saudi" then "Saudi Arabian" else
            if v = "senegalaise" then "Senegalese" else
            if v = "serb or serbian" then "Serbian" else
            if v = "serilankan" then "Sri Lankan" else
            if v = "siera leone" then "Sierra Leonean" else
            if v = "sieraleone" then "Sierra Leonean" else
            if v = "sierra leon" then "Sierra Leonean" else
            if v = "sierra leone" then "Sierra Leonean" else
            if v = "sierra leone- british" then "Sierra Leonean" else
            if v = "sierra leonian" then "Sierra Leonean" else
            if v = "sierraleon" then "Sierra Leonean" else
            if v = "sir lanka" then "Sri Lankan" else
            if v = "sirea leone" then "Sierra Leonean" else
            if v = "sirilankan" then "Sri Lankan" else
            if v = "sirlanakan" then "Sri Lankan" else
            if v = "sirra leonean" then "Sierra Leonean" else
            if v = "skovak" then "Slovak" else
            if v = "slovakian" then "Slovak" else
            if v = "somali, british" then "Somali" else
            if v = "somali-british" then "Somali" else
            if v = "somali/british" then "Somali" else
            if v = "somalia british" then "Somali" else
            if v = "somalian" then "Somali" else
            if v = "somalian - british" then "Somali" else
            if v = "somallian" then "Somali" else
            if v = "soudan" then "Sudanese" else
            if v = "south afrecan" then "South African" else
            if v = "south sudaneese" then "South Sudanese" else
            if v = "spanish" then "Spanish" else
            if v = "sri lankan" then "Sri Lankan" else
            if v = "sri lankan-british" then "Sri Lankan" else
            if v = "sri lnakan" then "Sri Lankan" else
            if v = "srilankan" then "Sri Lankan" else
            if v = "st chads and nevis" then "Kittitian" else
            if v = "st kitts" then "Kittitian" else
            if v = "st kitts & nevis" then "Kittitian" else
            if v = "st kitts and nevis" then "Kittitian" else
            if v = "st lucia" then "St Lucian" else
            if v = "st lucian" then "St Lucian" else
            if v = "st vincent" then "Vincentian" else
            if v = "sudan/dutch" then "Sudanese" else
            if v = "sudaneese" then "Sudanese" else
            if v = "sudanes" then "Sudanese" else
            if v = "sudanese-british" then "Sudanese" else
            if v = "sudani" then "Sudanese" else
            if v = "sudann" then "Sudanese" else
            if v = "sudian" then "Sudanese" else
            if v = "swazi/ british" then "Swazi" else
            if v = "swedish-iraqi" then "Swedish" else
            if v = "syran" then "Syrian" else
            if v = "syria british" then "Syrian" else
            if v = "syrian, british" then "Syrian" else
            if v = "tibetan" then "Stateless" else
            if v = "tndian" then "Indian" else
            if v = "trinida & tobago" then "Trinidadian" else
            if v = "trinidad & tobago" then "Trinidadian" else
            if v = "trinidardian" then "Trinidadian" else
            if v = "tunisan" then "Tunisian" else
            if v = "turk" then "Turkish" else
            if v = "turkish - british" then "Turkish" else
            if v = "turkmenian" then "Turkmen" else
            if v = "ugandian" then "Ugandan" else
            if v = "ukranian" then "Ukrainian" else
            if v = "vietnemese" then "Vietnamese" else
            if v = "yemani" then "Yemeni" else
            if v = "yugo" then "Serbian" else
            if v = "yugoslavian" then "Serbian" else
            if v = "zcech" then "Czech" else
            if v = "zceck" then "Czech" else
            if v = "zimbabean-british" then "Zimbabwean" else
            if v = "zimbabeian" then "Zimbabwean" else
            if v = "zimbabwean-british" then "Zimbabwean" else

            // iso codes and abbreviations
            if v = "civ" then "Ivorian" else
            if v = "cod" then "Congolese (DRC)" else
            if v = "sdn" then "Sudanese" else

            // geographic locations used instead of nationality
            if v = "nairobi" then "Kenyan" else       // city → country

            // contested/stateless cases
            if v = "tibet" then "Stateless" else
            if v = "tibet (china)" then "Stateless" else
            if v = "kwt-bedoon" then "Stateless" else  // bedoon = stateless kuwait residents

            // ethnic/language groups mapped to closest nationality
            if v = "kurdish" then "Iraqi" else          // no Kurdish nationality option exists
            if v = "kurdish/iraqi" then "Iraqi" else
            if v = "tigrinya" then "Eritrean" else      // tigrinya = eritrean/ethiopian language group

            // dual nationality entries — first-listed nationality used
            if v = "dual (usa & pakistani)" then "American" else
            if v = "italian/romanian" then "Italian" else
            if v = "moldovan/romanian" then "Moldovan" else
            if v = "sudan/dutch" then "Sudanese" else
            if v = "palastinain-polish" then "Palestinian" else

            // congo disambiguation
            // bare "Congo" → DRC (more common in this caseload context)
            if v = "congo" then "Congolese (DRC)" else
            if v = "congo drc" then "Congolese (DRC)" else
            if v = "orc congo" then "Congolese (DRC)" else
            if v = "zaire" then "Congolese (DRC)" else
            if v = "zaïrean" then "Congolese (DRC)" else

            // cote d'ivoire variants (apostrophe handling)
            if v = "cote d'ivoire" then "Ivorian" else
            if v = "côte d'ivoire" then "Ivorian" else
            if v = "ivory coast" then "Ivorian" else
            if v = "ivory" then "Ivorian" else
            if v = "ivoirian" then "Ivorian" else
            if v = "ivorienne" then "Ivorian" else

            // explicit invalid placeholders — administrative codes
            // entered in the nationality field in error
            if v = "ilr"     then "Invalid entry" else   // indefinite leave to remain (not a nationality)
            if v = "xxa"     then "Invalid entry" else   // placeholder/system code
            if v = "xxb"     then "Invalid entry" else   // placeholder/system code
            if v = "er"      then "Invalid entry" else   // fragment
            if v = "ian"     then "Invalid entry" else   // fragment
            if v = "unknown" then "Invalid entry" else   // explicit unknown
            if v = "."       then "Invalid entry" else   // punctuation placeholder

            // new variant not yet mapped — surfaces as null for review
            null
    ),

    #"Sorted Rows" = Table.Sort(#"Added Custom", {{"clean_nationality", Order.Ascending}})

in
    #"Sorted Rows"
