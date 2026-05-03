public with sharing class WC_ClaimAnalytics {

    public class AnalyticsRequest {
        @InvocableVariable(label='Metric Type' description='Required. One of: today, this_week, this_month, last_30_days, avg_amount_this_month, avg_amount_quarter, trending_parts_week, dealer_performance_month, period_comparison_month, high_value_claims.')
        public String metricType;
    }

    public class AnalyticsResponse {
        @InvocableVariable(label='Summary' description='Human-readable summary with INR formatted amounts.')
        public String summary;
        @InvocableVariable(label='Total Count' description='Total claim count for the metric window.')
        public Integer totalCount;
        @InvocableVariable(label='Approved Count' description='Count of Approved claims in window.')
        public Integer approvedCount;
        @InvocableVariable(label='Denied Count' description='Count of Denied claims in window.')
        public Integer deniedCount;
        @InvocableVariable(label='Pending Count' description='Count of pending-status claims in window.')
        public Integer pendingCount;
        @InvocableVariable(label='Approval Rate' description='Approval rate as decimal 0-100, computed Approved / (Approved + Denied) * 100.')
        public Decimal approvalRate;
        @InvocableVariable(label='Average Amount' description='Average TotalClaimedAmount in INR (raw number).')
        public Decimal averageAmount;
        @InvocableVariable(label='Error Message' description='Error details if processing failed.')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Get Claim Aggregate Analytics'
        description='Aggregate org-wide warranty claim metrics for the Claim Analytics topic. Returns counts grouped by status, approval rate, average amounts, trending parts, dealer performance, period comparisons. Use this instead of EmployeeCopilot__QueryRecords for analytics — it returns formatted aggregate results. Pass metricType to choose the metric.'
        callout=false)
    public static List<AnalyticsResponse> getAnalytics(List<AnalyticsRequest> reqs) {
        List<AnalyticsResponse> out = new List<AnalyticsResponse>();
        for (AnalyticsRequest req : reqs) {
            out.add(processOne(req));
        }
        return out;
    }

    private static AnalyticsResponse processOne(AnalyticsRequest req) {
        AnalyticsResponse r = new AnalyticsResponse();
        String metric = String.isBlank(req.metricType) ? 'this_month' : req.metricType.trim().toLowerCase();
        try {
            if (metric == 'today') {
                buildStatusBreakdown(r, 'TODAY', 'today', false);
            } else if (metric == 'this_week') {
                buildStatusBreakdown(r, 'THIS_WEEK', 'this week', false);
            } else if (metric == 'this_month') {
                buildStatusBreakdown(r, 'THIS_MONTH', 'this month', true);
            } else if (metric == 'last_30_days') {
                buildStatusBreakdown(r, 'LAST_N_DAYS:30', 'the last 30 days', false);
            } else if (metric == 'avg_amount_this_month') {
                buildAvgAmount(r, 'THIS_MONTH', 'this month');
            } else if (metric == 'avg_amount_quarter') {
                buildAvgAmount(r, 'LAST_N_DAYS:90', 'the last 90 days (quarter)');
            } else if (metric == 'trending_parts_week') {
                buildTrendingParts(r, 'THIS_WEEK', 'this week');
            } else if (metric == 'dealer_performance_month') {
                buildDealerPerformance(r);
            } else if (metric == 'period_comparison_month') {
                buildPeriodComparison(r);
            } else if (metric == 'high_value_claims') {
                buildHighValueClaims(r);
            } else {
                r.errorMessage = 'Unknown metricType: ' + metric;
            }
        } catch (Exception e) {
            r.errorMessage = 'Analytics failed: ' + e.getMessage();
        }
        return r;
    }

    private static void buildStatusBreakdown(AnalyticsResponse r, String dateLiteral, String label, Boolean autoFallback) {
        Map<String, Integer> counts = queryStatusCounts(dateLiteral);
        Integer total = sumValues(counts);
        if (total == 0 && autoFallback) {
            counts = queryStatusCounts('LAST_N_DAYS:30');
            total = sumValues(counts);
            if (total == 0) {
                r.summary = 'No claims found for ' + label + ' or last 30 days.';
                r.totalCount = 0;
                return;
            }
            label = label + ' (no data; using last 30 days)';
        } else if (total == 0) {
            r.summary = 'No claims found for ' + label + '.';
            r.totalCount = 0;
            return;
        }
        Integer approved = countOf(counts, 'Approved');
        Integer denied = countOf(counts, 'Denied');
        Integer pending = countOf(counts, 'New') + countOf(counts, 'Submitted')
                          + countOf(counts, 'Under Review') + countOf(counts, 'In Review')
                          + countOf(counts, 'Requested Information');
        Decimal rate = (approved + denied) > 0
            ? ((Decimal) approved / (Decimal) (approved + denied)) * 100
            : 0;
        r.totalCount = total;
        r.approvedCount = approved;
        r.deniedCount = denied;
        r.pendingCount = pending;
        r.approvalRate = rate.setScale(1);
        List<String> lines = new List<String>();
        lines.add('Claim summary for ' + label + ':');
        lines.add('Total: ' + total);
        for (String status : counts.keySet()) {
            lines.add('  ' + status + ': ' + counts.get(status));
        }
        if (approved + denied > 0) {
            lines.add('Approval rate: ' + rate.setScale(1) + '% (' + approved + ' approved / ' + (approved + denied) + ' decided)');
        }
        r.summary = String.join(lines, '\n');
    }

    private static Map<String, Integer> queryStatusCounts(String dateLiteral) {
        Map<String, Integer> counts = new Map<String, Integer>();
        String soql = 'SELECT Status, COUNT(Id) ct FROM Claim WHERE CreatedDate = ' + dateLiteral + ' GROUP BY Status';
        for (AggregateResult ar : Database.query(soql)) {
            String status = (String) ar.get('Status');
            Integer ct = ((Decimal) ar.get('ct')).intValue();
            counts.put(status, ct);
        }
        return counts;
    }

    private static void buildAvgAmount(AnalyticsResponse r, String dateLiteral, String label) {
        String soql = 'SELECT AVG(EstimatedAmount) avga, COUNT(Id) ct FROM Claim WHERE CreatedDate = ' + dateLiteral;
        AggregateResult[] rows = Database.query(soql);
        Decimal avg = null;
        Integer ct = 0;
        if (!rows.isEmpty()) {
            Object avgObj = rows[0].get('avga');
            if (avgObj != null) {
                avg = (Decimal) avgObj;
            }
            ct = ((Decimal) rows[0].get('ct')).intValue();
        }
        if (avg == null || ct == 0) {
            String fallback = 'SELECT AVG(EstimatedAmount) avga, COUNT(Id) ct FROM Claim WHERE CreatedDate = LAST_N_DAYS:30';
            rows = Database.query(fallback);
            if (!rows.isEmpty()) {
                Object avgObj = rows[0].get('avga');
                if (avgObj != null) {
                    avg = (Decimal) avgObj;
                }
                ct = ((Decimal) rows[0].get('ct')).intValue();
                label = label + ' (no data; using last 30 days)';
            }
        }
        if (avg == null || ct == 0) {
            r.summary = 'No claims found for ' + label + '.';
            r.totalCount = 0;
            return;
        }
        r.totalCount = ct;
        r.averageAmount = avg.setScale(2);
        r.summary = 'Average claim amount for ' + label + ': INR ' + avg.setScale(0).format()
                  + ' across ' + ct + ' claims.';
    }

    private static void buildTrendingParts(AnalyticsResponse r, String dateLiteral, String label) {
        String soql = 'SELECT CausalPartNumber__c part, COUNT(Id) ct FROM ClaimItem '
                    + 'WHERE Claim.CreatedDate = ' + dateLiteral + ' AND CausalPartNumber__c != null '
                    + 'GROUP BY CausalPartNumber__c ORDER BY COUNT(Id) DESC LIMIT 10';
        AggregateResult[] rows;
        try {
            rows = Database.query(soql);
        } catch (Exception e) {
            String fallback = 'SELECT CausalPartNumber__c part, COUNT(Id) ct FROM ClaimItem '
                            + 'WHERE Claim.CreatedDate = LAST_N_DAYS:30 AND CausalPartNumber__c != null '
                            + 'GROUP BY CausalPartNumber__c ORDER BY COUNT(Id) DESC LIMIT 10';
            rows = Database.query(fallback);
            label = label + ' (fallback to last 30 days)';
        }
        if (rows.isEmpty()) {
            String fallback = 'SELECT CausalPartNumber__c part, COUNT(Id) ct FROM ClaimItem '
                            + 'WHERE Claim.CreatedDate = LAST_N_DAYS:30 AND CausalPartNumber__c != null '
                            + 'GROUP BY CausalPartNumber__c ORDER BY COUNT(Id) DESC LIMIT 10';
            rows = Database.query(fallback);
            label = label + ' (fallback to last 30 days)';
        }
        if (rows.isEmpty()) {
            r.summary = 'No trending parts data for ' + label + '.';
            return;
        }
        List<String> lines = new List<String>();
        lines.add('Top failing parts for ' + label + ':');
        Integer rank = 1;
        for (AggregateResult ar : rows) {
            String part = (String) ar.get('part');
            Integer ct = ((Decimal) ar.get('ct')).intValue();
            lines.add(rank + '. ' + part + ' — ' + ct + ' claims');
            rank++;
        }
        r.summary = String.join(lines, '\n');
    }

    private static void buildDealerPerformance(AnalyticsResponse r) {
        AggregateResult[] rows = [
            SELECT Account.Name dealer, Status, COUNT(Id) ct
            FROM Claim
            WHERE CreatedDate = THIS_MONTH AND AccountId != null
            GROUP BY Account.Name, Status
            ORDER BY Account.Name
        ];
        if (rows.isEmpty()) {
            rows = [
                SELECT Account.Name dealer, Status, COUNT(Id) ct
                FROM Claim
                WHERE CreatedDate = LAST_N_DAYS:30 AND AccountId != null
                GROUP BY Account.Name, Status
                ORDER BY Account.Name
            ];
        }
        if (rows.isEmpty()) {
            r.summary = 'No dealer performance data this month or in the last 30 days.';
            return;
        }
        Map<String, Map<String, Integer>> byDealer = new Map<String, Map<String, Integer>>();
        for (AggregateResult ar : rows) {
            String d = (String) ar.get('dealer');
            String s = (String) ar.get('Status');
            Integer ct = ((Decimal) ar.get('ct')).intValue();
            if (!byDealer.containsKey(d)) {
                byDealer.put(d, new Map<String, Integer>());
            }
            byDealer.get(d).put(s, ct);
        }
        List<String> lines = new List<String>();
        lines.add('Dealer performance this month:');
        for (String d : byDealer.keySet()) {
            Map<String, Integer> sm = byDealer.get(d);
            Integer total = sumValues(sm);
            Integer approved = sm.containsKey('Approved') ? sm.get('Approved') : 0;
            lines.add(d + ' — total ' + total + ', approved ' + approved);
        }
        r.summary = String.join(lines, '\n');
    }

    private static void buildPeriodComparison(AnalyticsResponse r) {
        Map<String, Integer> thisMonth = queryStatusCounts('THIS_MONTH');
        Map<String, Integer> lastMonth = queryStatusCounts('LAST_MONTH');
        Integer ttotal = sumValues(thisMonth);
        Integer ltotal = sumValues(lastMonth);
        Integer tApproved = countOf(thisMonth, 'Approved');
        Integer lApproved = countOf(lastMonth, 'Approved');
        Decimal tRate = (countOf(thisMonth, 'Approved') + countOf(thisMonth, 'Denied')) > 0
            ? ((Decimal) tApproved / (Decimal) (countOf(thisMonth, 'Approved') + countOf(thisMonth, 'Denied'))) * 100
            : 0;
        Decimal lRate = (countOf(lastMonth, 'Approved') + countOf(lastMonth, 'Denied')) > 0
            ? ((Decimal) lApproved / (Decimal) (countOf(lastMonth, 'Approved') + countOf(lastMonth, 'Denied'))) * 100
            : 0;
        Integer delta = ttotal - ltotal;
        Decimal rateDelta = tRate - lRate;
        List<String> lines = new List<String>();
        lines.add('Period comparison — this month vs last month:');
        lines.add('This month: ' + ttotal + ' claims, ' + tApproved + ' approved, rate ' + tRate.setScale(1) + '%');
        lines.add('Last month: ' + ltotal + ' claims, ' + lApproved + ' approved, rate ' + lRate.setScale(1) + '%');
        lines.add('Delta: ' + (delta >= 0 ? '+' : '') + delta + ' claims, '
                  + (rateDelta >= 0 ? '+' : '') + rateDelta.setScale(1) + 'pp approval rate');
        r.summary = String.join(lines, '\n');
        r.totalCount = ttotal;
        r.approvedCount = tApproved;
        r.approvalRate = tRate.setScale(1);
    }

    private static void buildHighValueClaims(AnalyticsResponse r) {
        List<Claim> rows = [
            SELECT Id, Name, Account.Name, EstimatedAmount, Risk_Score__c
            FROM Claim
            WHERE EstimatedAmount > 500000
            ORDER BY EstimatedAmount DESC
            LIMIT 20
        ];
        if (rows.isEmpty()) {
            r.summary = 'No high-value claims (over INR 5,00,000) found.';
            return;
        }
        List<String> lines = new List<String>();
        lines.add('High-value claims over INR 5,00,000:');
        Integer rank = 1;
        Decimal total = 0;
        for (Claim c : rows) {
            String dealer = (c.Account != null) ? c.Account.Name : 'Unknown';
            Integer rs = (c.Risk_Score__c != null) ? c.Risk_Score__c.intValue() : 0;
            Decimal amt = c.EstimatedAmount != null ? c.EstimatedAmount : 0;
            total += amt;
            lines.add(rank + '. ' + c.Name + ' | INR ' + amt.setScale(0).format() + ' | Risk ' + rs + ' | ' + dealer);
            rank++;
        }
        r.totalCount = rows.size();
        r.averageAmount = (total / rows.size()).setScale(2);
        r.summary = String.join(lines, '\n');
    }

    private static Integer sumValues(Map<String, Integer> m) {
        Integer s = 0;
        for (Integer v : m.values()) {
            s += v;
        }
        return s;
    }

    private static Integer countOf(Map<String, Integer> m, String key) {
        return m.containsKey(key) ? m.get(key) : 0;
    }
}