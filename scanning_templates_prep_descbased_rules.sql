SELECT
    st.templateDesc,                          -- guideline name/description text
    st.TemplRule,
    st.RuleLimit,
    COUNT(*) AS OccurrenceCount,
    CASE WHEN st.templateDesc LIKE '%[0-9]%' THEN 1 ELSE 0 END AS HasDigit,
    CASE WHEN st.templateDesc LIKE '%max%' OR st.templateDesc LIKE '%limit%' THEN 1 ELSE 0 END AS MentionsMaxOrLimit,
    CASE WHEN st.templateDesc LIKE '%min%' THEN 1 ELSE 0 END AS MentionsMin
FROM mosaiqAdmin.dbo.TemplateOccurrencesExpanded toe
JOIN [hsc-cc-mqdb28].mosaiq.dbo.SchTempl st ON st.SCT_ID = toe.TemplatePK
WHERE toe.Block_Type = 'FREE_SLOT'   -- adjust column name to match what Stage 1 actually calls it
  AND ISNULL(st.RuleLimit, 0) = 0
GROUP BY st.templateDesc, st.TemplRule, st.RuleLimit
ORDER BY OccurrenceCount DESC;