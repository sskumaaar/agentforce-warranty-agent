/**
 * WC_DealerInsights
 * Single dispatcher Apex class powering 4 dealer-data Agentforce topics.
 * One @InvocableMethod, switched on Input.action:
 *   - list-claims  : recent claims for the running dealer (optional status filter)
 *   - high-risk    : claims with Risk_Score__c > 70
 *   - kpis         : KPI snapshot (reuses WC_DealerServicePortalController.getDealerPortalData)
 *   - performance  : monthly trend + category breakdown (reuses getPerformanceMetrics)
 *
 * `with sharing` — dealer's own data only. Cross-dealer data is intentionally NOT
 * exposed here; that lives in the dedicated cross-dealer flows.
 *
 * Errors are caught and returned as Output(success=false, message=...) so
 * Agentforce can render a clean message instead of a stack trace.
 */
public with sharing class WC_DealerInsights {

    private static final Integer DEFAULT_MAX = 6;
    private static final Integer HARD_MAX    = 50;
    private static final Integer HIGH_RISK_THRESHOLD = 70;

    @InvocableMethod(
        label='Dealer Claim Insights'
        description='Returns claim lists, high-risk claims, KPIs, or performance metrics for the running dealer. Pass action=list-claims | high-risk | kpis | performance.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> results = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            results.add(buildError(null, 'No input provided. Pass action=list-claims | high-risk | kpis | performance.'));
            return results;
        }

        // Agentforce invokes one record at a time but the framework requires List<Output>.
        // We process each input independently so a bad input cannot poison sibling rows.
        for (Input req : inputs) {
            try {
                String action = (req == null || req.action == null) ? null : req.action.trim().toLowerCase();
                if (action == 'list-claims') {
                    results.add(handleListClaims(req));
                } else if (action == 'high-risk') {
                    results.add(handleHighRisk(req));
                } else if (action == 'kpis') {
                    results.add(handleKpis());
                } else if (action == 'performance') {
                    results.add(handlePerformance());
                } else if (action == 'capabilities') {
                    results.add(handleCapabilities());
                } else if (action == 'greeting') {
                    results.add(handleGreeting());
                } else if (action == 'off-topic') {
                    results.add(handleOffTopic());
                } else if (action == 'warranty-info') {
                    results.add(handleWarrantyInfo());
                } else {
                    results.add(buildError(action,
                        'Unknown action: ' + (action == null ? 'null' : action) +
                        '. Valid: list-claims, high-risk, kpis, performance, capabilities, greeting, off-topic, warranty-info.'));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'WC_DealerInsights error: ' + e.getTypeName() + ' ' + e.getMessage());
                results.add(buildError(req == null ? null : req.action,
                    'Unable to complete request: ' + e.getMessage()));
            }
        }
        // Populate the deterministic JSON envelope on every Output. The bot's
        // topic instructions tell the Agentforce to respond with this string verbatim
        // so the LWC can parse it without prompt-template overhead.
        for (Output o : results) {
            o.formattedJson = buildFormattedJson(o);
        }
        return results;
    }

    /**
     * Serialize the Output as a strict-shape JSON envelope. Field order is
     * stable so prompt-engineering / regex-fallback work predictably.
     */
    private static String buildFormattedJson(Output o) {
        Map<String, Object> envelope = new Map<String, Object>();
        envelope.put('type', o.type);
        envelope.put('success', o.success);
        if (o.message != null)     envelope.put('message',     o.message);
        if (o.totalCount != null)  envelope.put('totalCount',  o.totalCount);
        if (o.shownCount != null)  envelope.put('shownCount',  o.shownCount);
        // [v22.8.A] Capabilities envelope fields.
        if (o.intro != null)       envelope.put('intro',       o.intro);
        if (o.footer != null)      envelope.put('footer',      o.footer);
        if (o.items != null)       envelope.put('items',       o.items);
        if (o.chips != null) {
            List<Map<String, Object>> arr = new List<Map<String, Object>>();
            for (CapabilityChip c : o.chips) {
                arr.add(new Map<String, Object>{
                    'icon'    => c.icon,
                    'label'   => c.label,
                    'triggerPhrase' => c.triggerPhrase
                });
            }
            envelope.put('chips', arr);
        }

        if (o.claims != null) {
            List<Map<String, Object>> arr = new List<Map<String, Object>>();
            for (ClaimSummary c : o.claims) {
                arr.add(new Map<String, Object>{
                    'claimId'        => c.claimId,
                    'claimNumber'    => c.claimNumber,
                    'status'         => c.status,
                    'severity'       => c.severity,
                    'totalAmount'    => c.totalAmount,
                    'initiationDate' => c.initiationDate == null ? null : String.valueOf(c.initiationDate),
                    'riskScore'      => c.riskScore,
                    'daysSinceFiled' => c.daysSinceFiled
                });
            }
            envelope.put('claims', arr);
        }
        if (o.kpis != null) {
            envelope.put('kpis', new Map<String, Object>{
                'actionRequired' => o.kpis.actionRequired,
                'openClaims'     => o.kpis.openClaims,
                'underReview'    => o.kpis.underReview,
                'approvedYTD'    => o.kpis.approvedYTD,
                'approvedCount'  => o.kpis.approvedCount,
                'approvalRate'   => o.kpis.approvalRate,
                'totalClaims'    => o.kpis.totalClaims,
                'fleetSize'      => o.kpis.fleetSize
            });
        }
        if (o.categories != null) {
            List<Map<String, Object>> arr = new List<Map<String, Object>>();
            for (CategoryBreakdown c : o.categories) {
                arr.add(new Map<String, Object>{
                    'category'   => c.category,
                    'count'      => c.count,
                    'percentage' => c.percentage
                });
            }
            envelope.put('categories', arr);
        }
        if (o.monthly != null) {
            List<Map<String, Object>> arr = new List<Map<String, Object>>();
            for (MonthlyData m : o.monthly) {
                arr.add(new Map<String, Object>{
                    'label'    => m.label,
                    'count'    => m.count,
                    'approved' => m.approved
                });
            }
            envelope.put('monthly', arr);
        }
        return JSON.serialize(envelope);
    }

    // ─── Action handlers ────────────────────────────────────────────────

    private static Output handleListClaims(Input req) {
        Output o = new Output();
        o.type = 'list-claims';
        o.claims = new List<ClaimSummary>();

        Id dealerAccId = getDealerAccountId();
        if (dealerAccId == null) {
            o.success = true;
            o.totalCount = 0;
            o.shownCount = 0;
            o.message = 'No dealer account is associated with the current user.';
            return o;
        }

        Integer limitN = clamp(req == null ? null : req.maxResults);
        String statusFilter = (req == null) ? null : req.statusFilter;
        Boolean useStatus = String.isNotBlank(statusFilter);

        // Total (un-clamped) count for the "showing X of Y" pattern. Bound at 2000
        // to stay well under SOQL row governor for very prolific dealers.
        Integer totalCount;
        if (useStatus) {
            totalCount = [
                SELECT COUNT() FROM Claim
                WHERE AccountId = :dealerAccId AND Status = :statusFilter
                LIMIT 2000
            ];
        } else {
            totalCount = [
                SELECT COUNT() FROM Claim
                WHERE AccountId = :dealerAccId
                LIMIT 2000
            ];
        }

        List<Claim> rows;
        if (useStatus) {
            rows = [
                SELECT Id, Name, Status, Severity, EstimatedAmount,
                       InitiationDate, Risk_Score__c, ClaimReason
                FROM Claim
                WHERE AccountId = :dealerAccId AND Status = :statusFilter
                ORDER BY LastModifiedDate DESC
                LIMIT :limitN
            ];
        } else {
            rows = [
                SELECT Id, Name, Status, Severity, EstimatedAmount,
                       InitiationDate, Risk_Score__c, ClaimReason
                FROM Claim
                WHERE AccountId = :dealerAccId
                ORDER BY LastModifiedDate DESC
                LIMIT :limitN
            ];
        }

        Date today = Date.today();
        for (Claim c : rows) {
            o.claims.add(toSummary(c, today));
        }
        o.success    = true;
        o.totalCount = totalCount;
        o.shownCount = o.claims.size();
        o.message    = useStatus
            ? ('Showing ' + o.shownCount + ' of ' + totalCount + ' claims with status "' + statusFilter + '".')
            : ('Showing ' + o.shownCount + ' of ' + totalCount + ' recent claims.');
        return o;
    }

    private static Output handleHighRisk(Input req) {
        Output o = new Output();
        o.type = 'high-risk';
        o.claims = new List<ClaimSummary>();

        Id dealerAccId = getDealerAccountId();
        if (dealerAccId == null) {
            o.success = true;
            o.totalCount = 0;
            o.shownCount = 0;
            o.message = 'No dealer account is associated with the current user.';
            return o;
        }

        Integer limitN = clamp(req == null ? null : req.maxResults);

        Integer totalCount = [
            SELECT COUNT() FROM Claim
            WHERE AccountId = :dealerAccId AND Risk_Score__c > :HIGH_RISK_THRESHOLD
            LIMIT 2000
        ];

        List<Claim> rows = [
            SELECT Id, Name, Status, Severity, EstimatedAmount,
                   InitiationDate, Risk_Score__c, ClaimReason
            FROM Claim
            WHERE AccountId = :dealerAccId AND Risk_Score__c > :HIGH_RISK_THRESHOLD
            ORDER BY Risk_Score__c DESC
            LIMIT :limitN
        ];

        Date today = Date.today();
        for (Claim c : rows) {
            o.claims.add(toSummary(c, today));
        }
        o.success    = true;
        o.totalCount = totalCount;
        o.shownCount = o.claims.size();
        o.message    = totalCount == 0
            ? 'No high-risk claims (Risk Score > 70) for this dealer.'
            : ('Showing ' + o.shownCount + ' of ' + totalCount + ' high-risk claims (Risk Score > 70).');
        return o;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Output handleKpis() {
        Output o = new Output();
        o.type = 'kpis';

        // Reuse the single source of truth — same KPI math the dealer LWC shows.
        Map<String, Object> portal = WC_DealerServicePortalController.getDealerPortalData();
        Map<String, Object> kpiMap = (portal == null) ? null : (Map<String, Object>) portal.get('kpis');

        KpiSnapshot k = new KpiSnapshot();
        if (kpiMap != null) {
            k.actionRequired = toInt(kpiMap.get('actionRequired'));
            k.openClaims     = toInt(kpiMap.get('openClaims'));
            k.underReview    = toInt(kpiMap.get('underReview'));
            k.approvedYTD    = toDecimal(kpiMap.get('approvedYTD'));
            k.approvedCount  = toInt(kpiMap.get('approvedCount'));
            k.approvalRate   = toDecimal(kpiMap.get('approvalRate'));
            k.totalClaims    = toInt(kpiMap.get('totalClaims'));
        }

        // Fleet size = Asset records owned by this dealer's Account.
        Id dealerAccId = getDealerAccountId();
        if (dealerAccId != null) {
            k.fleetSize = [SELECT COUNT() FROM Asset WHERE AccountId = :dealerAccId LIMIT 2000];
        } else {
            k.fleetSize = 0;
        }

        o.kpis    = k;
        o.success = true;
        o.message = 'KPI snapshot for the running dealer.';
        return o;
    }

    private static Output handlePerformance() {
        Output o = new Output();
        o.type = 'performance';
        o.categories = new List<CategoryBreakdown>();
        o.monthly    = new List<MonthlyData>();

        Map<String, Object> perf = WC_DealerServicePortalController.getPerformanceMetrics();
        if (perf == null || perf.isEmpty()) {
            o.success = true;
            o.message = 'No performance data available for this dealer.';
            return o;
        }

        // Monthly
        List<Object> rawMonthly = (List<Object>) perf.get('monthly');
        if (rawMonthly != null) {
            for (Object row : rawMonthly) {
                Map<String, Object> m = (Map<String, Object>) row;
                MonthlyData md = new MonthlyData();
                md.label    = (String) m.get('label');
                md.count    = toInt(m.get('count'));
                md.approved = toInt(m.get('approved'));
                o.monthly.add(md);
            }
        }

        // Categories — compute percentage = round(count / total * 100)
        List<Object> rawCats = (List<Object>) perf.get('categories');
        Integer catTotal = 0;
        if (rawCats != null) {
            for (Object row : rawCats) {
                Map<String, Object> m = (Map<String, Object>) row;
                catTotal += toInt(m.get('count'));
            }
            for (Object row : rawCats) {
                Map<String, Object> m = (Map<String, Object>) row;
                CategoryBreakdown cb = new CategoryBreakdown();
                cb.category   = (String) m.get('category');
                cb.count      = toInt(m.get('count'));
                cb.percentage = (catTotal > 0)
                    ? Integer.valueOf(((Decimal) cb.count / catTotal * 100).setScale(0, System.RoundingMode.HALF_UP))
                    : 0;
                o.categories.add(cb);
            }
        }

        o.success = true;
        o.message = 'Performance metrics: ' + o.monthly.size() + ' month(s), ' +
                    o.categories.size() + ' categor(ies).';
        return o;
    }

    /**
     * [v22.8.A] Handle "what can you do" / "help" / "capabilities" intent.
     * Returns a static chip list — pure metadata, no SOQL. The Agentforce (or the
     * js-primary local handler) echoes the JSON envelope verbatim and the
     * LWC renders clickable chips that re-feed the triggerPhrase phrase through
     * the chat.
     */
    private static Output handleCapabilities() {
        Output o = new Output();
        o.type = 'capabilities';
        o.success = true;
        o.intro = 'I am Atlas — your warranty copilot. I can:';
        o.chips = new List<CapabilityChip>();
        o.chips.add(buildChip('📄', 'File a warranty claim',  'file a warranty claim'));
        o.chips.add(buildChip('🔍', 'Check claim status',      'check status of WC-1001'));
        o.chips.add(buildChip('📋', 'Show recent claims',      'show recent claims'));
        o.chips.add(buildChip('⚠️',  'Show high-risk claims',   'show high risk claims'));
        o.chips.add(buildChip('📊', 'Approval rate / KPIs',    'what is my approval rate'));
        o.chips.add(buildChip('🚗', 'Check warranty by VIN',   'is warranty active for 1ELEC2025BOLT0001'));
        o.message = 'Showing capabilities chip card.';
        return o;
    }

    /**
     * [v22.8.B] Greeting — "hi", "hello", "good morning". Personalized with
     * dealer name + open-claim count when discoverable.
     */
    private static Output handleGreeting() {
        Output o = new Output();
        o.type = 'greeting';
        o.success = true;
        String dealerName = lookupDealerName();
        Integer openCount = lookupOpenClaimCount();
        String greet = 'Hi';
        if (String.isNotBlank(dealerName)) greet = 'Hi from ' + dealerName;
        if (openCount != null && openCount > 0) {
            greet += ' — you have ' + openCount + ' open claim' + (openCount == 1 ? '' : 's')
                  + ' right now. Try one of these to get started:';
        } else {
            greet += '. I help with warranty claims, status checks, and dealer KPIs. Try one of these:';
        }
        o.intro = greet;
        o.chips = new List<CapabilityChip>();
        o.chips.add(buildChip('📋', 'Show recent claims',     'show recent claims'));
        o.chips.add(buildChip('⚠️',  'Show high-risk claims',  'show high risk claims'));
        o.chips.add(buildChip('📊', 'My approval rate',       'what is my approval rate'));
        o.chips.add(buildChip('📄', 'File a warranty claim',  'file a warranty claim'));
        o.message = 'Showing personalized greeting.';
        return o;
    }

    /**
     * [v22.8.C] Off-topic redirect. The dealer asked about something outside
     * the warranty domain (other car brands, weather, jokes, chitchat). We
     * return a friendly redirect with on-topic suggestions.
     */
    private static Output handleOffTopic() {
        Output o = new Output();
        o.type = 'off-topic';
        o.success = true;
        o.intro = 'I focus on Electra warranty claims, status checks, vehicle and VIN lookups, and dealer KPIs. That one is outside what I can help with — but here is what I CAN do:';
        o.chips = new List<CapabilityChip>();
        o.chips.add(buildChip('📄', 'File a warranty claim',  'file a warranty claim'));
        o.chips.add(buildChip('🔍', 'Show recent claims',     'show recent claims'));
        o.chips.add(buildChip('⚠️',  'Show high-risk claims',  'show high risk claims'));
        o.message = 'Showing off-topic redirect.';
        return o;
    }

    /**
     * [v22.8.fix] Generic warranty FAQ — answers "what does warranty cover?"
     * WITHOUT requiring a VIN. The original Warranty Information topic
     * required a VIN and bot template fell back to a Lead offer when the
     * user asked the open question. This handler returns the standard
     * Electra warranty terms; the user can then provide a VIN for specifics.
     */
    private static Output handleWarrantyInfo() {
        Output o = new Output();
        o.type = 'warranty-info';
        o.success = true;
        o.intro = 'Standard Electra warranty coverage:';
        o.items = new List<String>();
        o.items.add('🔋 Battery cells & pack: 8 years / 160,000 km — manufacturing defects + capacity ≥70%');
        o.items.add('⚡ Drivetrain (motor, inverter, gearbox): 5 years / 100,000 km');
        o.items.add('💻 Electronics & software: 3 years / 60,000 km');
        o.items.add('🚗 Bumper-to-Bumper: 4 years / 50,000 km — parts + labour');
        o.items.add('🛞 Wear items (brakes, tires, wipers): NOT covered under standard warranty');
        o.footer = 'For a specific vehicle\'s status and end dates, share the VIN and I will look it up.';
        o.chips = new List<CapabilityChip>();
        o.chips.add(buildChip('🔍', 'Check warranty by VIN',  'is warranty active for 1ELEC2025BOLT0001'));
        o.chips.add(buildChip('📄', 'File a warranty claim',  'file a warranty claim'));
        o.chips.add(buildChip('📋', 'Show recent claims',     'show recent claims'));
        o.message = 'Showing generic warranty FAQ.';
        return o;
    }

    /** Best-effort dealer name lookup — returns null if not discoverable. */
    private static String lookupDealerName() {
        try {
            Id dealerAccId = getDealerAccountId();
            if (dealerAccId == null) return null;
            List<Account> accs = [SELECT Name FROM Account WHERE Id = :dealerAccId LIMIT 1];
            return accs.isEmpty() ? null : accs[0].Name;
        } catch (Exception e) {
            return null;
        }
    }

    /** Best-effort open-claim count — returns null if not discoverable. */
    private static Integer lookupOpenClaimCount() {
        try {
            Id dealerAccId = getDealerAccountId();
            if (dealerAccId == null) return null;
            return [
                SELECT COUNT()
                FROM   Claim
                WHERE  AccountId = :dealerAccId
                AND    Status IN ('New', 'Submitted', 'Under Review', 'Requested Information')
                LIMIT  2000
            ];
        } catch (Exception e) {
            return null;
        }
    }

    private static CapabilityChip buildChip(String icon, String label, String triggerPhrase) {
        CapabilityChip c = new CapabilityChip();
        c.icon    = icon;
        c.label   = label;
        c.triggerPhrase = triggerPhrase;
        return c;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static Id getDealerAccountId() {
        // Mirrors WC_DealerServicePortalController.getDealerAccountId logic.
        // Public method on that controller would be cleaner, but it's private — we
        // intentionally do NOT modify that file (per task contract), so re-derive here.
        List<User> users = [
            SELECT ContactId, AccountId FROM User
            WHERE Id = :UserInfo.getUserId() LIMIT 1
        ];
        if (users.isEmpty()) return null;
        if (users[0].AccountId != null) return users[0].AccountId;
        if (users[0].ContactId != null) {
            List<Contact> contacts = [
                SELECT AccountId FROM Contact
                WHERE Id = :users[0].ContactId LIMIT 1
            ];
            if (!contacts.isEmpty() && contacts[0].AccountId != null) return contacts[0].AccountId;
        }
        return null;
    }

    private static Integer clamp(Integer requested) {
        if (requested == null || requested <= 0) return DEFAULT_MAX;
        if (requested > HARD_MAX) return HARD_MAX;
        return requested;
    }

    private static ClaimSummary toSummary(Claim c, Date today) {
        ClaimSummary s = new ClaimSummary();
        s.claimId        = c.Id;
        s.claimNumber    = c.Name;
        s.status         = c.Status;
        s.severity       = c.Severity;
        s.totalAmount    = c.EstimatedAmount;
        s.initiationDate = (c.InitiationDate != null) ? c.InitiationDate.dateGmt() : null;
        s.riskScore      = (c.Risk_Score__c != null) ? c.Risk_Score__c.intValue() : null;
        s.daysSinceFiled = (c.InitiationDate != null) ? c.InitiationDate.dateGmt().daysBetween(today) : null;
        return s;
    }

    private static Output buildError(String action, String message) {
        Output o = new Output();
        o.success = false;
        o.type    = action;
        o.message = message;
        return o;
    }

    private static Integer toInt(Object v) {
        if (v == null) return 0;
        if (v instanceof Integer) return (Integer) v;
        if (v instanceof Decimal) return ((Decimal) v).intValue();
        if (v instanceof Long)    return ((Long) v).intValue();
        try { return Integer.valueOf(String.valueOf(v)); } catch (Exception e) { return 0; }
    }

    private static Decimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return Decimal.valueOf((Integer) v);
        if (v instanceof Long)    return Decimal.valueOf((Long) v);
        try { return Decimal.valueOf(String.valueOf(v)); } catch (Exception e) { return null; }
    }

    // ─── Invocable wrappers ─────────────────────────────────────────────

    public class Input {
        @InvocableVariable(required=true label='Action'
            description='One of: list-claims, high-risk, kpis, performance')
        public String action;

        @InvocableVariable(label='Status Filter'
            description='For action=list-claims only. Optional. One of: New, Submitted, Under Review, Approved, Denied, Requested Information. Omit for all statuses.')
        public String statusFilter;

        @InvocableVariable(label='Max Results'
            description='For action=list-claims and action=high-risk. Default 6, max 50.')
        public Integer maxResults;
    }

    public class Output {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String  type;
        @InvocableVariable public Integer totalCount;
        @InvocableVariable public Integer shownCount;
        @InvocableVariable public List<ClaimSummary> claims;
        @InvocableVariable public KpiSnapshot kpis;
        @InvocableVariable public List<CategoryBreakdown> categories;
        @InvocableVariable public List<MonthlyData> monthly;
        // [v22.8.A] Capability chips for the Help / "what can you do?" topic.
        @InvocableVariable public List<CapabilityChip> chips;
        @InvocableVariable public String intro;
        // [v22.8.fix] Warranty FAQ — bullet items + footer for the no-VIN generic answer.
        @InvocableVariable public List<String> items;
        @InvocableVariable public String footer;
        @InvocableVariable public String message;
        // Pre-serialized JSON envelope. The bot's topic instructions tell the
        // Agentforce to echo this value verbatim — gives the LWC a deterministic
        // JSON blob it can parse without an extra prompt-template hop. We
        // populate this in execute() right before returning the Output list.
        @InvocableVariable(label='Formatted JSON' description='Strict JSON envelope of the response. The bot MUST respond with this string exactly, no markdown, no extra text.')
        public String formattedJson;
    }

    public class ClaimSummary {
        @InvocableVariable public String  claimId;
        @InvocableVariable public String  claimNumber;
        @InvocableVariable public String  status;
        @InvocableVariable public String  severity;
        @InvocableVariable public Decimal totalAmount;
        @InvocableVariable public Date    initiationDate;
        @InvocableVariable public Integer riskScore;
        @InvocableVariable public Integer daysSinceFiled;
    }

    public class KpiSnapshot {
        @InvocableVariable public Integer actionRequired;
        @InvocableVariable public Integer openClaims;
        @InvocableVariable public Integer underReview;
        @InvocableVariable public Decimal approvedYTD;
        @InvocableVariable public Integer approvedCount;
        @InvocableVariable public Decimal approvalRate;
        @InvocableVariable public Integer totalClaims;
        @InvocableVariable public Integer fleetSize;
    }

    public class CategoryBreakdown {
        @InvocableVariable public String  category;
        @InvocableVariable public Integer count;
        @InvocableVariable public Integer percentage;
    }

    public class MonthlyData {
        @InvocableVariable public String  label;
        @InvocableVariable public Integer count;
        @InvocableVariable public Integer approved;
    }

    public class CapabilityChip {
        @InvocableVariable public String icon;     // emoji rendered in the LWC
        @InvocableVariable public String label;    // user-visible text
        @InvocableVariable public String triggerPhrase;  // phrase fed back through chat when tapped
    }
}