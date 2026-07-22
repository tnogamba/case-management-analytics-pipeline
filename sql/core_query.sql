-- ============================================================
-- casework_analytics.v_all_interactions
-- grain: one row per action/contact
-- purpose: replaces manual crm exports with a governed,
--          analysis-ready flat structure for bi reporting
--
-- two views intended:
--   v_all_interactions_full      : all columns including pii
--   v_all_interactions_analytics : pii columns excluded
--
-- architecture notes:
--   - source uses eav pattern for client and case attributes
--     (client_attributes, case_attributes tables)
--   - household relationships stored in a separate link table
--     (client_relationships) with many-to-many potential
--   - previous case ownership stored in a separate audit table
--     (case_ownership_history) with no deleted flag
--   - soft delete pattern: deleted_at datetime is null = active
--     (exception: lookup table uses is_active bit flag)
--   - nolock hints applied throughout - read-only analytics
--     account, acceptable read consistency trade-off
--
-- last verified: june 2026
-- author: tess ogamba · github.com/tessogamba
-- ============================================================


-- ============================================================
-- cte 1: pivot client_attributes eav into flat demographics
-- ============================================================
-- the source crm stores all client-level attributes in a
-- single entity-attribute-value table (client_attributes).
-- this cte pivots 36 named fields into a wide flat structure
-- using max(case when) aggregation, grouped by client id.
-- pii fields are included here and excluded downstream
-- in the analytics view.
-- ============================================================
with client_demographics as (
    select
        attr_client_id,

        -- identity
        max(case when attr_field = 'Surname'        then attr_value end)    as [Surname],
        max(case when attr_field = 'First Names'    then attr_value end)    as [First Names],
        max(case when attr_field = 'Known As'       then attr_value end)    as [Known As],
        max(case when attr_field = 'Date Of Birth'  then attr_value end)    as [Date of Birth],

        -- contact — pii, excluded from analytics view
        max(case when attr_field = 'Mobile Number'  then attr_value end)    as [Mobile Number],
        max(case when attr_field = 'Email'          then attr_value end)    as [Email],

        -- address — pii, excluded from analytics view
        max(case when attr_field = 'House Number'   then attr_value end)    as [House Number],
        max(case when attr_field = 'Address Line 1' then attr_value end)    as [Address Line 1],
        max(case when attr_field = 'Address Line 2' then attr_value end)    as [Address Line 2],
        max(case when attr_field = 'Post Code'      then attr_value end)    as [Post Code],
        max(case when attr_field = 'Town'           then attr_value end)    as [Town],

        -- demographics
        max(case when attr_field = 'Nationality'           then attr_value end)  as [Nationality],
        max(case when attr_field = 'Gender'                then attr_value end)  as [Gender],
        max(case when attr_field = 'Gender At Birth'       then attr_value end)  as [Gender Assigned at Birth],
        max(case when attr_field = 'Ethnic Origin'         then attr_value end)  as [Ethnic Origin],
        max(case when attr_field = 'Religion'              then attr_value end)  as [Religion],
        max(case when attr_field = 'Marital Status'        then attr_value end)  as [Marital Status],
        max(case when attr_field = 'Sexual Orientation'    then attr_value end)  as [Sexual Orientation],
        max(case when attr_field = 'Disability'            then attr_value end)  as [Disability],
        max(case when attr_field = 'Spoken Language'       then attr_value end)  as [Spoken Language],
        max(case when attr_field = 'English Proficiency'   then attr_value end)  as [English Proficiency],
        max(case when attr_field = 'Date Of Arrival'       then attr_value end)  as [Date of Arrival],

        -- socioeconomic
        max(case when attr_field = 'Employment Status' then attr_value end)  as [Employment Status],
        max(case when attr_field = 'Housing Status'    then attr_value end)  as [Housing Status],
        max(case when attr_field = 'Housing Provider'  then attr_value end)  as [Housing Provider],

        -- immigration status (client-level, captured at registration)
        max(case when attr_field = 'Immigration Status'        then attr_value end)  as [Client Immigration Status],
        max(case when attr_field = 'Status Date Granted'       then attr_value end)  as [Client Immigration Status Grant Date],
        max(case when attr_field = 'Status Expiry Date'        then attr_value end)  as [Client Immigration Status Expiry Date],

        -- government reference numbers — pii, excluded from analytics view
        max(case when attr_field = 'National Insurance No'     then attr_value end)  as [NINO],
        max(case when attr_field = 'Home Office Ref'           then attr_value end)  as [HO Ref Number],
        max(case when attr_field = 'Asylum Support Ref'        then attr_value end)  as [NASS Ref Number],

        -- next of kin — pii, excluded from analytics view
        max(case when attr_field = 'Next Of Kin Name'          then attr_value end)  as [Next of Kin Name],
        max(case when attr_field = 'Next Of Kin Contact'       then attr_value end)  as [Next of Kin Contact Number],

        -- inbound referral (how the client came to the organisation)
        max(case when attr_field = 'Referral Source'           then attr_value end)  as [Inbound Referral Agency],
        max(case when attr_field = 'Referral Route'            then attr_value end)  as [Inbound Signpost Route],

        -- project tagging
        max(case when attr_field = 'Project Tag'               then attr_value end)  as [Client Project Tag]

    from client_attributes (nolock)
    where attr_deleted_at is null
    group by attr_client_id
),


-- ============================================================
-- cte 2: pivot case_attributes eav into flat case fields
-- ============================================================
-- same eav pattern as client_attributes but at case/enquiry
-- level. five fields captured here including project tagging,
-- referral source tracking and vulnerability flags.
-- ============================================================
case_attributes_flat as (
    select
        case_attr_case_id,
        max(case when case_attr_field = 'Project Tag'             then case_attr_value end)  as [Case Project Tag],
        max(case when case_attr_field = 'Project Tag 2'           then case_attr_value end)  as [Case Project Tag 2],
        max(case when case_attr_field = 'Referral Source'         then case_attr_value end)  as [How did they hear about us?],
        max(case when case_attr_field = 'Signpost Source'         then case_attr_value end)  as [Referral/signposting source],
        max(case when case_attr_field = 'Vulnerabilities'         then case_attr_value end)  as [Vulnerabilities]
    from case_attributes (nolock)
    where case_attr_deleted_at is null
    group by case_attr_case_id
),


-- ============================================================
-- cte 3: household reference resolution
-- ============================================================
-- clients exist in household relationships stored in a
-- separate link table (client_relationships) with a
-- many-to-many structure. one client can belong to multiple
-- households over time (e.g. family separation, remarriage).
--
-- resolution logic:
--   col_1 = the dependent/household member
--   col_2 = the main applicant / household reference
--
-- row_number() partitioned by dependent, ordered by created
-- date descending ensures the most recent household link wins
-- where a client has been linked to multiple households.
--
-- fallback via coalesce in main select:
--   if no household record exists → show own client reference
--   (main applicants with no dependents registered)
-- ============================================================
household_reference as (
    select
        rel_client_id           as client_id,
        rel_household_ref_id    as [Household Reference]
    from (
        select
            rel_client_id,
            rel_household_ref_id,
            row_number() over (
                partition by rel_client_id
                order by rel_created_at desc
            ) as rn
        from client_relationships (nolock)
        where rel_deleted_at is null
    ) ranked
    where rn = 1
),


-- ============================================================
-- cte 4: previous case owners
-- ============================================================
-- the crm maintains an audit trail of case ownership changes
-- in a separate table (case_ownership_history). this table
-- has no deleted column — every row is a permanent record.
--
-- string_agg() concatenates all previous owners per case
-- into a comma-separated string for reporting.
-- ============================================================
previous_owners as (
    select
        hist_case_id,
        string_agg(hist_previous_owner, ', ')   as [Previous Owners]
    from case_ownership_history (nolock)
    group by hist_case_id
)


-- ============================================================
-- main select
-- ============================================================
select

    -- ----------------------------------------------------------
    -- client identifiers
    -- ----------------------------------------------------------
    cl.client_id                                                            as [Client Reference],

    -- household reference with three-way fallback:
    --   1. has a client_relationships record → use household ref
    --   2. is_primary_client flag = 1 → use own client id
    --   3. neither → null (data quality gap / migration record)
    case
        when hr.[Household Reference] is not null   then hr.[Household Reference]
        when cl.is_primary_client = 1               then cl.client_id
        else null
    end                                                                     as [Household Reference],

    cl.is_primary_client                                                    as [Is Main Client],
    cl.created_at                                                           as [Client Added Date],
    cl.created_by                                                           as [Client Added By],

    -- ----------------------------------------------------------
    -- client demographics (from client_demographics cte)
    -- ----------------------------------------------------------
    [Surname],
    [First Names],
    [Date of Birth],
    [Nationality],
    [Gender],
    [Gender Assigned at Birth],
    [Ethnic Origin],
    [Religion],
    [Marital Status],
    [Sexual Orientation],
    [Disability],
    [Spoken Language],
    [English Proficiency],
    [Date of Arrival],

    -- ----------------------------------------------------------
    -- client socioeconomic
    -- ----------------------------------------------------------
    [Employment Status],
    [Housing Status],
    [Housing Provider],

    -- ----------------------------------------------------------
    -- client immigration status (registration-level snapshot)
    -- ----------------------------------------------------------
    [Client Immigration Status],
    [Client Immigration Status Grant Date],
    [Client Immigration Status Expiry Date],

    -- ----------------------------------------------------------
    -- inbound referral (who referred the client to the org)
    -- ----------------------------------------------------------
    [Inbound Referral Agency],
    [Inbound Signpost Route],

    -- ----------------------------------------------------------
    -- client project tagging
    -- ----------------------------------------------------------
    [Client Project Tag],

    -- ----------------------------------------------------------
    -- pii columns — excluded in analytics view
    -- ----------------------------------------------------------
    [Mobile Number],
    [Email],
    [House Number],
    [Address Line 1],
    [Address Line 2],
    [Post Code],
    [Town],
    [Known As],
    [NINO],
    [HO Ref Number],
    [NASS Ref Number],
    [Next of Kin Name],
    [Next of Kin Contact Number],

    -- ----------------------------------------------------------
    -- case / enquiry details
    -- ----------------------------------------------------------
    cs.case_id                                                              as [Enquiry Reference],
    cs.case_date                                                            as [Enquiry Date],
    cs.case_created_by                                                      as [Enquiry Created By],
    cs.case_type                                                            as [Enquiry Type],
    cs.case_owner                                                           as [Enquiry Owner],
    po.[Previous Owners],
    cs.case_current_status                                                  as [Enquiry Immigration Status],
    cs.case_status_grant_date                                               as [Current Status Grant Date],
    cs.case_status_expiry_date                                              as [Current Status Expiry Date],
    cs.case_consent_type                                                    as [Consent Type],
    cs.case_q1_answer                                                       as [Q1 Answer],
    cs.case_q2_answer                                                       as [Q2 Answer],
    cs.case_q3_answer                                                       as [Q3 Answer],
    cs.case_desired_outcome                                                 as [Desired Outcome],
    cs.case_notes                                                           as [Enquiry Info],
    cs.case_actual_outcome                                                  as [Actual Outcome],
    cs.case_outcome_reason                                                  as [Outcome Reason],
    cs.case_closed_at                                                       as [Enquiry Closed Date],
    cs.case_closed_by                                                       as [Enquiry Closed By],

    -- ----------------------------------------------------------
    -- case attribute fields (from case_attributes_flat cte)
    -- ----------------------------------------------------------
    [Case Project Tag],
    [How did they hear about us?],
    [Referral/signposting source],
    [Vulnerabilities],

    -- ----------------------------------------------------------
    -- contact / action details
    -- ----------------------------------------------------------
    ac.action_date                                                          as [Action Date],
    ac.action_by                                                            as [Action By],
    ac.action_type                                                          as [Action Type],
    ac.action_duration_mins                                                 as [Action Time],
    ac.action_notes                                                         as [Action Info],
    ac.action_deadline_date                                                 as [Action Deadline Date],

    -- ----------------------------------------------------------
    -- outbound referral and signpost
    -- both stored in same columns on the action record,
    -- separated here by filtering on action_type
    -- ----------------------------------------------------------
    case when ac.action_type = 'Referral' then ac.action_referral_org  end  as [Referral Agency],
    case when ac.action_type = 'Referral' then ac.action_referral_date end  as [Referral Date],
    case when ac.action_type = 'Signpost' then ac.action_referral_org  end  as [Signpost Agency],
    case when ac.action_type = 'Signpost' then ac.action_referral_date end  as [Signpost Date],

    -- ----------------------------------------------------------
    -- staff details (action owner)
    -- ----------------------------------------------------------
    st.staff_access_level                                                   as [Staff Access Level],
    st.staff_primary_site                                                   as [Staff Site],

    -- ----------------------------------------------------------
    -- window functions — calculated at enquiry grain
    -- these run across all actions per case, returning the
    -- same value on every action row for a given case.
    -- power bi deduplicates to case grain in dim_enquiry.
    -- ----------------------------------------------------------

    -- most recent action date on this case
    max(ac.action_date) over (
        partition by ac.action_case_id
    )                                                                       as [Last Action Date],

    -- furthest upcoming deadline across all actions on this case
    max(ac.action_deadline_date) over (
        partition by ac.action_case_id
    )                                                                       as [Latest Deadline Date],

    -- total time logged across all actions on this case (minutes)
    sum(ac.action_duration_mins) over (
        partition by ac.action_case_id
    )                                                                       as [Enquiry Time],

    -- notes from the most recent action on this case
    first_value(ac.action_notes) over (
        partition by ac.action_case_id
        order by ac.action_date desc
    )                                                                       as [Last Action Info]


from contacts ac (nolock)

-- case / enquiry
left join cases cs (nolock)
    on ac.action_case_id = cs.case_id
    and cs.case_deleted_at is null

-- client via case-client link table
-- note: do not join directly on client_id from the action record —
-- the correct path is action → case → case_client_link → client
left join case_client_link ccl (nolock)
    on cs.case_id = ccl.link_case_id
    and ccl.link_deleted_at is null

left join clients cl (nolock)
    on ccl.link_client_id = cl.client_id
    and cl.client_deleted_at is null

-- action owner staff record
left join staff st (nolock)
    on ac.action_by = st.staff_username
    and st.staff_deleted_at is null

-- case owner staff record (username already on case table;
-- join here to pull access level and site if needed)
left join staff st_case (nolock)
    on cs.case_owner = st_case.staff_username
    and st_case.staff_deleted_at is null

-- client demographics eav pivot
left join client_demographics cd (nolock)
    on cd.attr_client_id = cl.client_id

-- case attribute fields eav pivot
left join case_attributes_flat caf (nolock)
    on caf.case_attr_case_id = cs.case_id

-- household reference resolution
left join household_reference hr (nolock)
    on hr.client_id = cl.client_id

-- previous case owners audit trail
left join previous_owners po (nolock)
    on po.hist_case_id = cs.case_id

where ac.action_deleted_at is null
  and cl.client_id is not null

-- end of query
-- ============================================================
-- pii exclusion note:
-- to create the analytics view, exclude the following columns
-- from the select list above:
--   [Mobile Number], [Email], [House Number], [Address Line 1],
--   [Address Line 2], [Post Code], [Town], [Known As],
--   [NINO], [HO Ref Number], [NASS Ref Number],
--   [Next of Kin Name], [Next of Kin Contact Number]
-- ============================================================
