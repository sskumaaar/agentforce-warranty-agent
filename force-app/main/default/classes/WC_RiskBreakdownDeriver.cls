public with sharing class WC_RiskBreakdownDeriver {

    public static final String METHODOLOGY = 'electra_triage_v1.1';

    public static String deriveJson(Claim c) {
        return deriveJson(c, null, null, null, countComebacks(c));
    }

    public static String deriveJson(Claim c, Vehicle v, AssetWarranty aw, WarrantyTerm wt) {
        return deriveJson(c, v, aw, wt, countComebacks(c));
    }

    /**
     * Bulk-friendly overload. Caller passes the comeback count for this claim
     * (computed once outside the loop) so derive doesn't burn one SOQL per
     * claim. Used by backfillBreakdownsForOpenClaims.
     */
    public static String deriveJson(Claim c, Vehicle v, AssetWarranty aw, WarrantyTerm wt,
                                    Integer priorComebackCount) {
        Map<String, Object> root = new Map<String, Object>();
        root.put('version', METHODOLOGY);
        root.put('calculatedAt', Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));

        List<Map<String, Object>> factors = new List<Map<String, Object>>();
        Decimal contribSum = 0;
        Integer flaggedCount = 0;

        Map<String, Object> f;
        f = buildSeverityFactor(c); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildMileageFactor(c, wt); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildRoundMileageFactor(c); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildComebackFactor(c, priorComebackCount); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildWarrantyFactor(c, aw); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildDocFactor(c); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildAmountFactor(c); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildClaimAgeFactor(c); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }
        f = buildChannelFactor(c); if (f != null) { factors.add(f); contribSum += toDec(f.get('contribution')); if (f.get('verdict') == 'fail') flaggedCount++; }

        Decimal targetScore = c.Risk_Score__c != null ? c.Risk_Score__c : contribSum;
        Decimal residual = targetScore - contribSum;

        root.put('factors', factors);
        root.put('baseline', 0);
        root.put('totalContribution', contribSum);
        root.put('finalScore', targetScore);
        root.put('residual', residual);
        root.put('summary', buildSummary(flaggedCount, residual));

        return JSON.serialize(root);
    }

    public static Decimal computeConfidence(Claim c) {
        Integer pts = 35;
        if (String.isNotBlank(c.Severity)) pts += 8;
        if (c.MileageAtClaim__c != null) pts += 10;
        if (String.isNotBlank(c.DiagnosticTroubleCode__c)) pts += 10;
        if (String.isNotBlank(c.FailureDescription__c) && c.FailureDescription__c.length() >= 30) pts += 10;
        if (c.EstimatedAmount != null) pts += 8;
        if (String.isNotBlank(c.Channel__c)) pts += 5;
        if (String.isNotBlank(c.RepairOrderNumber__c)) pts += 7;
        if (c.InitiationDate != null) pts += 5;
        if (pts > 100) pts = 100;
        return Decimal.valueOf(pts);
    }

    public static void backfillBreakdownsForOpenClaims(Integer maxRecords) {
        backfillBreakdownsForOpenClaims(maxRecords, false);
    }

    public static void backfillBreakdownsForOpenClaims(Integer maxRecords, Boolean force) {
        Integer cap = (maxRecords == null || maxRecords <= 0) ? 200 : maxRecords;
        String whereClause = force
            ? 'Risk_Score__c != null'
            : 'Risk_Score__c != null AND Risk_Score_Methodology__c = null';
        String soql = 'SELECT Id, Name, Risk_Score__c, Risk_Score_Breakdown__c, Risk_Score_Methodology__c, '
            + 'Risk_Score_Calculated_At__c, Risk_Score_Confidence__c, Severity, '
            + 'MileageAtClaim__c, DiagnosticTroubleCode__c, FailureDescription__c, '
            + 'RepairOrderNumber__c, EstimatedAmount, Channel__c, InitiationDate, '
            + 'Vehicle_VIN__c, ClaimReason, AccountId '
            + 'FROM Claim WHERE ' + whereClause + ' LIMIT ' + cap;
        List<Claim> targets = Database.query(soql);
        if (targets.isEmpty()) return;

        // Bulk-prepare comeback counts in ONE aggregate SOQL — avoids N+1.
        Map<Id, Integer> comebackByClaimId = bulkComebackCounts(targets);

        List<Claim> updates = new List<Claim>();
        for (Claim c : targets) {
            Integer prior = comebackByClaimId.containsKey(c.Id) ? comebackByClaimId.get(c.Id) : 0;
            updates.add(new Claim(
                Id = c.Id,
                Risk_Score_Breakdown__c = deriveJson(c, null, null, null, prior),
                Risk_Score_Methodology__c = METHODOLOGY,
                Risk_Score_Calculated_At__c = Datetime.now(),
                Risk_Score_Confidence__c = computeConfidence(c)
            ));
        }
        update updates;
    }

    /**
     * For each target, count claims sharing its (VIN, ClaimReason) within the
     * last 90 days, EXCLUDING the target itself. Single aggregate SOQL keeps
     * the bulk path within governor limits even for 200 targets.
     */
    private static Map<Id, Integer> bulkComebackCounts(List<Claim> targets) {
        Set<String> vins = new Set<String>();
        Set<String> reasons = new Set<String>();
        for (Claim c : targets) {
            if (String.isNotBlank(c.Vehicle_VIN__c)) vins.add(c.Vehicle_VIN__c);
            if (String.isNotBlank(c.ClaimReason))    reasons.add(c.ClaimReason);
        }
        Map<Id, Integer> out = new Map<Id, Integer>();
        if (vins.isEmpty() || reasons.isEmpty()) {
            for (Claim c : targets) out.put(c.Id, 0);
            return out;
        }
        Datetime cutoff = Datetime.now().addDays(-90);
        Map<String, Integer> totalByKey = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Vehicle_VIN__c vin, ClaimReason cr, COUNT(Id) cnt
            FROM   Claim
            WHERE  Vehicle_VIN__c IN :vins
            AND    ClaimReason    IN :reasons
            AND    CreatedDate    >= :cutoff
            GROUP BY Vehicle_VIN__c, ClaimReason
        ]) {
            String key = (String) ar.get('vin') + '|' + (String) ar.get('cr');
            totalByKey.put(key, Integer.valueOf(ar.get('cnt')));
        }
        for (Claim c : targets) {
            String key = (c.Vehicle_VIN__c == null ? '' : c.Vehicle_VIN__c)
                       + '|' + (c.ClaimReason == null ? '' : c.ClaimReason);
            Integer total = totalByKey.containsKey(key) ? totalByKey.get(key) : 0;
            out.put(c.Id, Math.max(0, total - 1));  // exclude self
        }
        return out;
    }

    /**
     * Single-claim convenience — used when deriveJson is called outside a
     * bulk loop (e.g. side-panel single-claim view). 1 SOQL.
     *
     * Wrapped in try/catch on the field reads because callers may pass a
     * Claim queried without Vehicle_VIN__c / ClaimReason — older code paths
     * (existing tests, ad-hoc invocations) won't include the new fields.
     * Returning 0 is the safe default; the comeback factor simply won't fire.
     */
    private static Integer countComebacks(Claim c) {
        if (c == null) return 0;
        String vin;
        String reason;
        try {
            vin    = c.Vehicle_VIN__c;
            reason = c.ClaimReason;
        } catch (System.SObjectException sObjectEx) {
            return 0;
        }
        if (String.isBlank(vin) || String.isBlank(reason)) return 0;
        Datetime cutoff = Datetime.now().addDays(-90);
        Integer total = [
            SELECT COUNT()
            FROM   Claim
            WHERE  Vehicle_VIN__c = :vin
            AND    ClaimReason    = :reason
            AND    CreatedDate    >= :cutoff
        ];
        if (c.Id != null) {
            // Exclude the target's own row from the count.
            return Math.max(0, total - 1);
        }
        return total;
    }

    private static Map<String, Object> buildSeverityFactor(Claim c) {
        if (String.isBlank(c.Severity)) return null;
        String sev = c.Severity;
        Decimal contrib; String verdict; String value;
        if (sev == 'Critical') { contrib = 15; verdict = 'fail'; value = 'Severity: Critical — safety/operability impact'; }
        else if (sev == 'High') { contrib = 8; verdict = 'warning'; value = 'Severity: High — significant impact reported'; }
        else if (sev == 'Medium') { contrib = 2; verdict = 'neutral'; value = 'Severity: Medium — standard impact'; }
        else { contrib = -3; verdict = 'pass'; value = 'Severity: ' + sev + ' — limited impact'; }
        return new Map<String, Object>{
            'name' => 'Reported Severity',
            'value' => value,
            'weight' => 0.15,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => 'Claim.Severity'
        };
    }

    private static Map<String, Object> buildClaimAgeFactor(Claim c) {
        if (c.InitiationDate == null) return null;
        Long hoursOld = (Datetime.now().getTime() - c.InitiationDate.getTime()) / (1000 * 60 * 60);
        Decimal contrib; String verdict; String value;
        if (hoursOld < 0) { contrib = 0; verdict = 'neutral'; value = 'Future-dated claim'; }
        else if (hoursOld > 120) { contrib = 5; verdict = 'warning'; value = 'Claim is ' + (hoursOld / 24) + ' days old — SLA pressure'; }
        else if (hoursOld > 48) { contrib = 2; verdict = 'neutral'; value = 'Open ' + hoursOld + ' hours — within review window'; }
        else { contrib = -1; verdict = 'pass'; value = 'Recently submitted (' + hoursOld + ' hours ago)'; }
        return new Map<String, Object>{
            'name' => 'Claim Age / SLA Position',
            'value' => value,
            'weight' => 0.05,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => 'Claim.InitiationDate'
        };
    }

    private static Map<String, Object> buildMileageFactor(Claim c, WarrantyTerm wt) {
        if (c.MileageAtClaim__c == null) return null;
        Decimal claimMiles = c.MileageAtClaim__c;
        Boolean limitKnown = (wt != null && wt.UsageCovered != null && wt.UsageCovered > 0);
        Decimal contrib;
        String verdict;
        String value;
        String reference;
        if (!limitKnown) {
            contrib = 0;
            verdict = 'neutral';
            value = claimMiles.format() + ' mi at claim — warranty mileage limit not on record (cannot evaluate)';
            reference = 'Claim.MileageAtClaim__c (no WarrantyTerm linked)';
        } else {
            Decimal coveredLimit = wt.UsageCovered;
            Decimal pctOfLimit = (claimMiles / coveredLimit) * 100;
            if (pctOfLimit > 100) { contrib = 22; verdict = 'fail'; }
            else if (pctOfLimit > 80) { contrib = 12; verdict = 'warning'; }
            else if (pctOfLimit > 50) { contrib = 4; verdict = 'neutral'; }
            else { contrib = -3; verdict = 'pass'; }
            value = claimMiles.format() + ' mi at claim / ' + coveredLimit.format() + ' mi covered ('
                + pctOfLimit.setScale(0, System.RoundingMode.HALF_UP) + '% of limit)';
            reference = 'WarrantyTerm.UsageCovered';
        }
        return new Map<String, Object>{
            'name' => 'Mileage vs Warranty Limit',
            'value' => value,
            'weight' => 0.20,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => reference
        };
    }

    /**
     * Round-number mileage fraud signal. Industry red-flag: dealers fabricating
     * a service visit often write the odometer in clean thousands. Axiom and
     * WarrantyWeek list this as a top fraud indicator. Tier 1 (most suspicious):
     * mileage divisible by 1000 (e.g. 50000, 75000). Tier 2: divisible by 100
     * but not 1000 (e.g. 42500, 67800). Below 100 miles is a fresh-vehicle
     * delivery scenario — not suspicious, skip.
     */
    private static Map<String, Object> buildRoundMileageFactor(Claim c) {
        if (c.MileageAtClaim__c == null) return null;
        Decimal miles = c.MileageAtClaim__c;
        if (miles < 1000) return null;
        Long m = miles.longValue();
        Decimal contrib;
        String verdict;
        String value;
        if (Math.mod(m, 1000) == 0) {
            contrib = 5;
            verdict = 'warning';
            value = miles.format() + ' — round 1000s. Verify odometer photo (industry fraud red-flag)';
        } else if (Math.mod(m, 100) == 0) {
            contrib = 2;
            verdict = 'neutral';
            value = miles.format() + ' — round 100s. Worth a quick double-check';
        } else {
            return null;
        }
        return new Map<String, Object>{
            'name' => 'Round-Number Mileage',
            'value' => value,
            'weight' => 0.05,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => 'Claim.MileageAtClaim__c (Axiom / WarrantyWeek fraud signal)'
        };
    }

    /**
     * Comeback / repeat-repair fraud signal. Industry standard (Axiom,
     * WarrantyWeek): same VIN + same ClaimReason within 90 days indicates
     * either an incomplete prior repair or fraud (parts-swap, ghost repair).
     * Caller passes priorCount so this stays SOQL-free for bulk paths.
     */
    private static Map<String, Object> buildComebackFactor(Claim c, Integer priorCount) {
        if (priorCount == null || priorCount <= 0) return null;
        Decimal contrib;
        String verdict;
        String value;
        if (priorCount >= 2) {
            contrib = 18;
            verdict = 'fail';
            value = priorCount + ' prior claims same VIN + category in 90 days — multi-comeback';
        } else {
            contrib = 10;
            verdict = 'warning';
            value = '1 prior claim same VIN + category within 90 days — comeback';
        }
        return new Map<String, Object>{
            'name'         => 'Repeat Repair / Comeback',
            'value'        => value,
            'weight'       => 0.15,
            'contribution' => contrib,
            'verdict'      => verdict,
            'reference'    => 'Claim history (90d window, same VIN + ClaimReason)'
        };
    }

    private static Map<String, Object> buildWarrantyFactor(Claim c, AssetWarranty aw) {
        Date refDate = (c.InitiationDate != null) ? c.InitiationDate.date() : Date.today();
        Decimal contrib;
        String verdict;
        String value;
        String ref = (aw != null) ? 'AssetWarranty:' + aw.Id : 'No linked AssetWarranty record';
        if (aw == null) {
            contrib = 0; verdict = 'neutral';
            value = 'No AssetWarranty linked to this claim — coverage status cannot be evaluated';
        } else if (aw.EndDate != null && aw.EndDate < refDate) {
            contrib = 25; verdict = 'fail';
            value = 'Warranty expired ' + aw.EndDate.format() + ' before claim ' + refDate.format();
        } else if (aw.StartDate != null && aw.StartDate > refDate) {
            contrib = 20; verdict = 'fail';
            value = 'Warranty starts ' + aw.StartDate.format() + ', after claim ' + refDate.format();
        } else {
            Integer daysLeft = (aw.EndDate != null) ? refDate.daysBetween(aw.EndDate) : 365;
            if (daysLeft < 30) { contrib = 8; verdict = 'warning'; value = daysLeft + ' days remaining on warranty'; }
            else { contrib = -5; verdict = 'pass'; value = 'Active warranty (' + daysLeft + ' days remaining)'; }
        }
        return new Map<String, Object>{
            'name' => 'Warranty Coverage Status',
            'value' => value,
            'weight' => 0.25,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => ref
        };
    }

    private static Map<String, Object> buildDocFactor(Claim c) {
        Boolean hasDtc = String.isNotBlank(c.DiagnosticTroubleCode__c);
        Integer descLen = String.isNotBlank(c.FailureDescription__c) ? c.FailureDescription__c.length() : 0;
        Boolean hasDesc = descLen >= 30;
        Boolean hasRO = String.isNotBlank(c.RepairOrderNumber__c);
        Integer score = (hasDtc ? 1 : 0) + (hasDesc ? 1 : 0) + (hasRO ? 1 : 0);
        Decimal contrib; String verdict;
        if (score == 3) { contrib = -4; verdict = 'pass'; }
        else if (score == 2) { contrib = 2; verdict = 'neutral'; }
        else if (score == 1) { contrib = 8; verdict = 'warning'; }
        else { contrib = 14; verdict = 'fail'; }
        List<String> parts = new List<String>();
        parts.add('DTC ' + (hasDtc ? c.DiagnosticTroubleCode__c : '—'));
        parts.add('RO ' + (hasRO ? c.RepairOrderNumber__c : '—'));
        if (descLen == 0) parts.add('Description: missing');
        else if (!hasDesc) parts.add('Description: too short (' + descLen + ' chars, need 30+)');
        else parts.add('Description: ' + descLen + ' chars');
        return new Map<String, Object>{
            'name' => 'Documentation Quality',
            'value' => String.join(parts, ' · '),
            'weight' => 0.10,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => 'Claim.DiagnosticTroubleCode__c, FailureDescription__c, RepairOrderNumber__c'
        };
    }

    private static Map<String, Object> buildAmountFactor(Claim c) {
        if (c.EstimatedAmount == null) return null;
        Decimal amt = c.EstimatedAmount;
        Decimal contrib; String verdict; String value;
        if (amt > 100000) { contrib = 18; verdict = 'fail'; value = 'High exposure: ' + amt.format(); }
        else if (amt > 50000) { contrib = 10; verdict = 'warning'; value = 'Above typical: ' + amt.format(); }
        else if (amt > 10000) { contrib = 3; verdict = 'neutral'; value = 'Typical claim: ' + amt.format(); }
        else { contrib = -2; verdict = 'pass'; value = 'Low-value claim: ' + amt.format(); }
        return new Map<String, Object>{
            'name' => 'Claim Amount',
            'value' => value,
            'weight' => 0.20,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => 'Claim.EstimatedAmount'
        };
    }

    private static Map<String, Object> buildChannelFactor(Claim c) {
        if (String.isBlank(c.Channel__c)) return null;
        String ch = c.Channel__c;
        Decimal contrib; String verdict; String value;
        if (ch == 'WhatsApp' || ch == 'Web_Chat') { contrib = 4; verdict = 'neutral'; value = 'Conversational channel: ' + ch; }
        else if (ch == 'Portal') { contrib = -2; verdict = 'pass'; value = 'Authenticated portal submission'; }
        else if (ch == 'Email') { contrib = 1; verdict = 'neutral'; value = 'Email submission'; }
        else { contrib = 0; verdict = 'neutral'; value = ch; }
        return new Map<String, Object>{
            'name' => 'Reporting Channel',
            'value' => value,
            'weight' => 0.05,
            'contribution' => contrib,
            'verdict' => verdict,
            'reference' => 'Claim.Channel__c'
        };
    }

    private static String buildSummary(Integer flaggedCount, Decimal residual) {
        String base;
        if (flaggedCount == 0) base = 'All visible factors within normal parameters.';
        else base = flaggedCount + (flaggedCount == 1 ? ' factor' : ' factors') + ' flagged from claim data.';
        if (residual != null && residual.abs() >= 5) {
            base += ' Proprietary triage signals contributed ' + (residual >= 0 ? '+' : '') + residual.intValue() + ' (vehicle/dealer history, recall data, telemetry).';
        }
        return base;
    }

    private static Decimal toDec(Object o) {
        if (o == null) return 0;
        if (o instanceof Decimal) return (Decimal) o;
        if (o instanceof Integer) return Decimal.valueOf((Integer) o);
        return Decimal.valueOf(String.valueOf(o));
    }
}