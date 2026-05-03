/**
 * WCDealerPerformanceMetricsController
 * Returns performance metrics for the Dealer Portal Performance Metrics LWC.
 * Uses the standard Claim and ClaimItem objects with corrected field names
 * per FIELD_NAME_CORRECTIONS_CRITICAL.md:
 *   - Claim is STANDARD (no __c)
 *   - InitiationDate  = filed date (Datetime)
 *   - Status          = claim status (standard picklist)
 *   - FinalizedDate   = closed/approved date (Datetime)
 *   - ClaimItem.Category = item category (via subquery on ClaimItems)
 */
public with sharing class WCDealerPerformanceMetricsController {

    // ─── Wrapper: top-level response ───────────────────────────────────────────
    public class MetricsData {
        @AuraEnabled public List<MonthBar>    claimsPerMonth    { get; set; }
        @AuraEnabled public List<CategoryBar> categoryBreakdown { get; set; }
        @AuraEnabled public Decimal           avgResolutionDays { get; set; }

        public MetricsData() {
            this.claimsPerMonth    = new List<MonthBar>();
            this.categoryBreakdown = new List<CategoryBar>();
            this.avgResolutionDays = 0;
        }
    }

    // ─── Bar for monthly claims chart ──────────────────────────────────────────
    public class MonthBar {
        @AuraEnabled public String  monthLabel { get; set; }
        @AuraEnabled public Integer count      { get; set; }
        @AuraEnabled public Integer heightPct  { get; set; }  // % of max, drives bar height

        public MonthBar(String label, Integer cnt) {
            this.monthLabel = label;
            this.count      = cnt;
            this.heightPct  = 0;
        }
    }

    // ─── Bar for category horizontal chart ─────────────────────────────────────
    public class CategoryBar {
        @AuraEnabled public String  category { get; set; }
        @AuraEnabled public Integer count    { get; set; }
        @AuraEnabled public Integer widthPct { get; set; }  // % of max, drives bar width

        public CategoryBar(String cat, Integer cnt) {
            this.category = cat;
            this.count    = cnt;
            this.widthPct = 0;
        }
    }

    // ─── Month abbreviation lookup ──────────────────────────────────────────────
    private static final List<String> MONTH_ABBREVS = new List<String>{
        'Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'
    };

    // ─── Main wire-compatible method ────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static MetricsData getMetrics() {
        MetricsData result = new MetricsData();

        result.claimsPerMonth    = buildClaimsPerMonth();
        result.categoryBreakdown = buildCategoryBreakdown();
        result.avgResolutionDays = calcAvgResolutionDays();

        return result;
    }

    // ─── 1. Claims filed per month for last 6 months ────────────────────────────
    private static List<MonthBar> buildClaimsPerMonth() {

        // Build a map of (year * 100 + month) -> count from SOQL aggregate
        Map<Integer, Integer> countByYearMonth = new Map<Integer, Integer>();

        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(InitiationDate) yr,
                   CALENDAR_MONTH(InitiationDate) mo,
                   COUNT(Id) cnt
            FROM Claim
            WHERE InitiationDate = LAST_N_MONTHS:6
            WITH SECURITY_ENFORCED
            GROUP BY CALENDAR_YEAR(InitiationDate), CALENDAR_MONTH(InitiationDate)
        ]) {
            Integer yr  = (Integer) ar.get('yr');
            Integer mo  = (Integer) ar.get('mo');
            Integer cnt = (Integer) ar.get('cnt');
            countByYearMonth.put(yr * 100 + mo, cnt);
        }

        // Build the last-6-months ordered list dynamically
        List<MonthBar> bars = new List<MonthBar>();
        Date today = Date.today();

        for (Integer offset = 5; offset >= 0; offset--) {
            // Step back 'offset' months from start of this month
            Date d   = today.toStartOfMonth().addMonths(-offset);
            Integer yr = d.year();
            Integer mo = d.month();

            String label = MONTH_ABBREVS[mo - 1] + ' ' + String.valueOf(yr).right(2);
            Integer key  = yr * 100 + mo;
            Integer cnt  = countByYearMonth.containsKey(key)
                           ? countByYearMonth.get(key)
                           : 0;
            bars.add(new MonthBar(label, cnt));
        }

        // Compute heightPct relative to max
        Integer maxCount = 0;
        for (MonthBar b : bars) {
            if (b.count > maxCount) maxCount = b.count;
        }
        if (maxCount > 0) {
            for (MonthBar b : bars) {
                b.heightPct = (Integer) Math.round((Decimal) b.count / maxCount * 100);
            }
        }

        return bars;
    }

    // ─── 2. Category breakdown — top 4 ClaimItem categories ────────────────────
    private static List<CategoryBar> buildCategoryBreakdown() {
        List<CategoryBar> bars = new List<CategoryBar>();

        for (AggregateResult ar : [
            SELECT Category cat, COUNT(Id) cnt
            FROM ClaimItem
            WHERE Category != null
            WITH SECURITY_ENFORCED
            GROUP BY Category
            ORDER BY COUNT(Id) DESC
            LIMIT 4
        ]) {
            String  cat = (String)  ar.get('cat');
            Integer cnt = (Integer) ar.get('cnt');
            bars.add(new CategoryBar(cat, cnt));
        }

        // Compute widthPct relative to max (first row = max after ORDER BY DESC)
        Integer maxCount = bars.isEmpty() ? 0 : bars[0].count;
        if (maxCount > 0) {
            for (CategoryBar b : bars) {
                b.widthPct = (Integer) Math.round((Decimal) b.count / maxCount * 100);
            }
        }

        return bars;
    }

    // ─── 3. Average resolution days for Approved/Settled claims ─────────────────
    private static Decimal calcAvgResolutionDays() {
        // Query Approved/Settled claims in the last 6 months that have a FinalizedDate
        List<Claim> claims = [
            SELECT InitiationDate, FinalizedDate
            FROM Claim
            WHERE Status IN ('Approved', 'Settled')
              AND FinalizedDate != null
              AND InitiationDate = LAST_N_MONTHS:6
            WITH SECURITY_ENFORCED
        ];

        if (claims.isEmpty()) {
            return 0;
        }

        Decimal totalDays = 0;
        Integer validCount = 0;

        for (Claim c : claims) {
            if (c.InitiationDate != null && c.FinalizedDate != null) {
                // Both are Datetime; difference in milliseconds converted to days
                Long diffMs   = c.FinalizedDate.getTime() - c.InitiationDate.getTime();
                Decimal days  = diffMs / 86400000.0;
                if (days >= 0) {
                    totalDays += days;
                    validCount++;
                }
            }
        }

        if (validCount == 0) {
            return 0;
        }

        return (totalDays / validCount).setScale(1);
    }
}