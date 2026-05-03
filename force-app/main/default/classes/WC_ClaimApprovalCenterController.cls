public without sharing class WC_ClaimApprovalCenterController {

    private static final Set<String> PENDING_STATUSES = new Set<String>{
        'New', 'Under Review', 'Submitted'
    };

    public class ClaimWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String statusCode;
        @AuraEnabled public String severity;
        @AuraEnabled public Integer riskScore;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public Decimal estimatedAmount;
        @AuraEnabled public Decimal approvedAmount;
        @AuraEnabled public String dealerName;
        @AuraEnabled public String summary;
        @AuraEnabled public String aiRecommendation;
        @AuraEnabled public String aiTriageNotes;
        @AuraEnabled public String triageFlags;
        @AuraEnabled public String channel;
        @AuraEnabled public Datetime initiationDate;
        @AuraEnabled public Datetime lastModifiedDate;
        @AuraEnabled public String approverComments;
        @AuraEnabled public Integer slaHoursRemaining;
        @AuraEnabled public String riskCssClass;
        @AuraEnabled public String slaCssClass;
        @AuraEnabled public String statusCssClass;
        @AuraEnabled public String rowCssClass;
        @AuraEnabled public String ownerId;
        @AuraEnabled public String ownerName;
        // [v20] Surface dealer's latest reply so OEM bell can preview it
        @AuraEnabled public String dealerResponse;
    }

    public class ClaimDetailWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String statusCode;
        @AuraEnabled public String severity;
        @AuraEnabled public Integer riskScore;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public Decimal estimatedAmount;
        @AuraEnabled public Decimal approvedAmount;
        @AuraEnabled public String dealerName;
        @AuraEnabled public String summary;
        @AuraEnabled public String aiRecommendation;
        @AuraEnabled public String aiTriageNotes;
        @AuraEnabled public String channel;
        @AuraEnabled public Datetime initiationDate;
        @AuraEnabled public Datetime lastModifiedDate;
        @AuraEnabled public Datetime finalizedDate;
        @AuraEnabled public String approverComments;
        @AuraEnabled public Integer slaHoursRemaining;
        @AuraEnabled public String riskCssClass;
        @AuraEnabled public String slaCssClass;
        @AuraEnabled public String statusCssClass;
        @AuraEnabled public String rowCssClass;
        @AuraEnabled public String approvedBy;
        @AuraEnabled public String rejectedBy;
        // [v22.4] Decision attribution — "Atlas AI Triage" when auto-decided.
        @AuraEnabled public String decidedByName;
        @AuraEnabled public Boolean decidedByAutoTriage;
        @AuraEnabled public Datetime approvalDate;
        @AuraEnabled public String rejectionReason;
        @AuraEnabled public Decimal mileageAtClaim;
        @AuraEnabled public String diagnosticTroubleCode;
        @AuraEnabled public String failureDescription;
        @AuraEnabled public String dealerCode;
        @AuraEnabled public String repairOrderNumber;
        @AuraEnabled public String vehicleVin;
        @AuraEnabled public String vehicleMake;
        @AuraEnabled public String vehicleModel;
        @AuraEnabled public String vehicleYear;
        @AuraEnabled public String vehicleColor;
        @AuraEnabled public Decimal vehicleMileage;
        @AuraEnabled public String warrantyCoverage;
        @AuraEnabled public Date warrantyStartDate;
        @AuraEnabled public Date warrantyEndDate;
        @AuraEnabled public RiskBreakdown riskBreakdown;
        @AuraEnabled public String riskBreakdownMethodology;
        @AuraEnabled public Datetime riskBreakdownCalculatedAt;
        @AuraEnabled public Decimal riskBreakdownConfidence;
        // v9: parsed entries from Conversation_Log__c (OEM ↔ Dealer back-and-forth thread).
        @AuraEnabled public List<ClaimConversationService.Entry> conversationEntries;
    }

    public class RiskBreakdown {
        @AuraEnabled public String version;
        @AuraEnabled public String calculatedAt;
        @AuraEnabled public String summary;
        @AuraEnabled public Decimal baseline;
        @AuraEnabled public Decimal totalContribution;
        @AuraEnabled public Decimal finalScore;
        @AuraEnabled public Decimal residual;
        @AuraEnabled public List<RiskFactor> factors;
        @AuraEnabled public Boolean truncated;
    }

    public class RiskFactor {
        @AuraEnabled public String name;
        @AuraEnabled public String value;
        @AuraEnabled public Decimal weight;
        @AuraEnabled public Decimal contribution;
        @AuraEnabled public String verdict;
        @AuraEnabled public String reference;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getApprovalDashboardData() {
        List<Claim> claims = [
            SELECT Id, Name, Status, StatusCode, Severity, Summary, EstimatedAmount, ApprovedAmount,
                   AccountId, Account.Name, InitiationDate, LastModifiedDate, FinalizedDate,
                   Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c, Triage_Flags__c, Channel__c,
                   Approver_Comments__c, Dealer_Response__c,
                   ApprovedBy__c, RejectedBy__c, ApprovalDate__c, RejectionReason__c,
                   OwnerId, Owner.Name
            FROM Claim
            ORDER BY Risk_Score__c DESC NULLS LAST, InitiationDate ASC
            LIMIT 49000
        ];

        List<ClaimWrapper> wrappers = new List<ClaimWrapper>();
        Map<String, Integer> riskDistribution = new Map<String, Integer>{
            'Low' => 0, 'Medium' => 0, 'High' => 0, 'Critical' => 0
        };
        Map<String, Integer> slaBuckets = new Map<String, Integer>{
            'within24h' => 0, 'within48h' => 0, 'within72h' => 0, 'breach' => 0
        };
        Map<String, Integer> statusDistribution = new Map<String, Integer>();

        Integer totalPending = 0;
        Decimal highRiskAmount = 0;
        Integer approvedToday = 0;
        Integer rejectedToday = 0;
        Integer resolvedCount = 0;
        Long totalProcessingDays = 0;
        Integer slaBreaches = 0;
        Integer aiTriaged = 0;
        Integer autoApproved = 0;
        Integer autoDenied = 0;
        Integer reviewRouted = 0;
        Integer investigateRouted = 0;
        Integer followUpRouted = 0;
        Long autoProcessingDays = 0;
        Integer autoResolvedCount = 0;
        Long humanProcessingDays = 0;
        Integer humanResolvedCount = 0;
        Datetime now = Datetime.now();
        Date today = Date.today();

        for (Claim c : claims) {
            ClaimWrapper w = mapClaimToWrapper(c, now);
            wrappers.add(w);

            Boolean isPending = PENDING_STATUSES.contains(c.Status);

            if (isPending) {
                totalPending++;

                if (c.Risk_Score__c != null && c.Risk_Score__c > 60) {
                    highRiskAmount += (c.EstimatedAmount != null ? c.EstimatedAmount : 0);
                }

                String riskBucket = getRiskLevel(c.Risk_Score__c);
                riskDistribution.put(riskBucket, riskDistribution.get(riskBucket) + 1);

                if (c.InitiationDate != null) {
                    Long hoursSince = getHoursSince(c.InitiationDate, now);
                    if (hoursSince <= 24) {
                        slaBuckets.put('within24h', slaBuckets.get('within24h') + 1);
                    } else if (hoursSince <= 48) {
                        slaBuckets.put('within48h', slaBuckets.get('within48h') + 1);
                    } else if (hoursSince <= 72) {
                        slaBuckets.put('within72h', slaBuckets.get('within72h') + 1);
                    } else {
                        slaBuckets.put('breach', slaBuckets.get('breach') + 1);
                    }

                    if (c.InitiationDate < now.addDays(-3)) {
                        slaBreaches++;
                    }
                }
            }

            if (c.Status == 'Approved' && c.LastModifiedDate != null && c.LastModifiedDate.date() == today) {
                approvedToday++;
            }
            if (c.Status == 'Denied' && c.LastModifiedDate != null && c.LastModifiedDate.date() == today) {
                rejectedToday++;
            }

            String aiRec = c.AI_Recommendation__c;
            if (String.isNotBlank(aiRec)) {
                aiTriaged++;
                if (aiRec == 'Auto-Approved') autoApproved++;
                else if (aiRec == 'Auto-Denied') autoDenied++;
                else if (aiRec == 'Review') reviewRouted++;
                else if (aiRec == 'Investigate') investigateRouted++;
                else if (aiRec == 'Follow-Up') followUpRouted++;
            }

            if (c.InitiationDate != null && c.FinalizedDate != null) {
                Long days = c.InitiationDate.date().daysBetween(c.FinalizedDate.date());
                totalProcessingDays += days;
                resolvedCount++;
                Boolean isAutoRoute = (aiRec == 'Auto-Approved' || aiRec == 'Auto-Denied');
                if (isAutoRoute) { autoProcessingDays += days; autoResolvedCount++; }
                else if (String.isNotBlank(aiRec)) { humanProcessingDays += days; humanResolvedCount++; }
            }

            String statusKey = c.Status != null ? c.Status : 'Unknown';
            statusDistribution.put(statusKey,
                (statusDistribution.containsKey(statusKey) ? statusDistribution.get(statusKey) : 0) + 1);
        }

        Decimal avgProcessingDays = resolvedCount > 0
            ? Decimal.valueOf(totalProcessingDays).divide(resolvedCount, 1)
            : 0;
        Decimal avgAutoResolution = autoResolvedCount > 0
            ? Decimal.valueOf(autoProcessingDays).divide(autoResolvedCount, 1)
            : 0;
        Decimal avgHumanResolution = humanResolvedCount > 0
            ? Decimal.valueOf(humanProcessingDays).divide(humanResolvedCount, 1)
            : 0;

        Integer totalCount = claims.size();
        Integer fullyAutomated = autoApproved + autoDenied;
        Decimal automationRate = totalCount > 0
            ? Decimal.valueOf(fullyAutomated * 100).divide(totalCount, 1) : 0;
        Decimal aiAssistedRate = totalCount > 0
            ? Decimal.valueOf(aiTriaged * 100).divide(totalCount, 1) : 0;

        Map<String, Object> kpis = new Map<String, Object>{
            'totalPending' => totalPending,
            'highRiskAmount' => highRiskAmount,
            'approvedToday' => approvedToday,
            'rejectedToday' => rejectedToday,
            'avgProcessingDays' => avgProcessingDays,
            'slaBreaches' => slaBreaches,
            'totalClaims' => totalCount
        };

        Integer namedRoutes = autoApproved + autoDenied + reviewRouted + investigateRouted + followUpRouted;
        Integer otherAiCount = aiTriaged - namedRoutes;

        Map<String, Object> automationMetrics = new Map<String, Object>{
            'aiTriaged' => aiTriaged,
            'autoApproved' => autoApproved,
            'autoDenied' => autoDenied,
            'reviewRouted' => reviewRouted,
            'investigateRouted' => investigateRouted,
            'followUpRouted' => followUpRouted,
            'otherAiCount' => otherAiCount,
            'fullyAutomated' => fullyAutomated,
            'automationRate' => automationRate,
            'aiAssistedRate' => aiAssistedRate,
            'avgAutoResolution' => avgAutoResolution,
            'avgHumanResolution' => avgHumanResolution,
            'totalClaims' => totalCount,
            'noAiCount' => totalCount - aiTriaged
        };

        return new Map<String, Object>{
            'claims' => wrappers,
            'kpis' => kpis,
            'riskDistribution' => riskDistribution,
            'slaBuckets' => slaBuckets,
            'statusDistribution' => statusDistribution,
            'automationMetrics' => automationMetrics
        };
    }

    @AuraEnabled
    public static List<Map<String, Object>> getClaimComments(Id claimId) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (WC_Claim_Comment__c c : [
            SELECT Id, Body__c, Author_Name__c, Comment_Type__c, CreatedDate, CreatedById
            FROM WC_Claim_Comment__c
            WHERE Claim__c = :claimId
            ORDER BY CreatedDate ASC
        ]) {
            result.add(new Map<String, Object>{
                'id' => c.Id,
                'body' => c.Body__c,
                'authorName' => c.Author_Name__c,
                'commentType' => c.Comment_Type__c,
                'createdDate' => c.CreatedDate,
                'createdById' => c.CreatedById
            });
        }
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> createClaimComment(Id claimId, String body, String authorName, String commentType) {
        if (String.isBlank(body)) {
            throw new AuraHandledException('Electra Cars claim comment: body is required.');
        }
        WC_Claim_Comment__c c = new WC_Claim_Comment__c(
            Claim__c = claimId,
            Body__c = body,
            Author_Name__c = authorName,
            Comment_Type__c = String.isNotBlank(commentType) ? commentType : 'General'
        );
        insert c;
        return new Map<String, Object>{
            'id' => c.Id,
            'success' => true
        };
    }

    @AuraEnabled
    public static ClaimDetailWrapper getClaimDetail(String claimId) {
        if (String.isBlank(claimId)) {
            throw new AuraHandledException('Claim ID is required to view Electra Cars warranty claim details.');
        }

        List<Claim> claims = [
            SELECT Id, Name, Status, StatusCode, Severity, Summary, EstimatedAmount, ApprovedAmount,
                   AccountId, Account.Name, InitiationDate, LastModifiedDate, FinalizedDate,
                   Risk_Score__c, AI_Recommendation__c, AI_Triage_Notes__c, Channel__c,
                   Risk_Score_Breakdown__c, Risk_Score_Methodology__c,
                   Risk_Score_Calculated_At__c, Risk_Score_Confidence__c,
                   Approver_Comments__c,
                   ApprovedBy__c, ApprovedBy__r.Name,
                   RejectedBy__c, RejectedBy__r.Name,
                   ApprovalDate__c, RejectionReason__c,
                   MileageAtClaim__c, DiagnosticTroubleCode__c, FailureDescription__c,
                   DealerCode__c, RepairOrderNumber__c,
                   Conversation_Log__c,
                   OwnerId, Owner.Name
            FROM Claim
            WHERE Id = :claimId
            LIMIT 1
        ];

        if (claims.isEmpty()) {
            throw new AuraHandledException('Electra Cars warranty claim not found: ' + claimId);
        }

        Claim c = claims[0];
        Datetime now = Datetime.now();
        ClaimDetailWrapper detail = new ClaimDetailWrapper();
        copyBaseFields(c, detail, now);
        attachRiskBreakdown(c, detail);
        detail.conversationEntries = ClaimConversationService.parseEntries(c.Conversation_Log__c);

        Id vehicleId = null;
        Id assetId = null;

        List<ClaimItem> claimItems = [
            SELECT VehicleId, Vehicle.AssetId
            FROM ClaimItem
            WHERE ClaimId = :c.Id AND VehicleId != null
            LIMIT 1
        ];
        if (!claimItems.isEmpty()) {
            vehicleId = claimItems[0].VehicleId;
            assetId = claimItems[0].Vehicle.AssetId;
        } else if (c.AccountId != null) {
            List<Vehicle> fallbackVehicles = [
                SELECT Id, AssetId FROM Vehicle
                WHERE AssetId IN (SELECT Id FROM Asset WHERE AccountId = :c.AccountId)
                LIMIT 1
            ];
            if (!fallbackVehicles.isEmpty()) {
                vehicleId = fallbackVehicles[0].Id;
                assetId = fallbackVehicles[0].AssetId;
            }
        }

        if (vehicleId != null) {
            Vehicle v = [
                SELECT Id, Name, VehicleIdentificationNumber, MakeName, ModelName,
                       ModelYear, ExteriorColor, LastOdometerReading
                FROM Vehicle WHERE Id = :vehicleId LIMIT 1
            ];
            detail.vehicleVin = v.VehicleIdentificationNumber;
            detail.vehicleMake = v.MakeName;
            detail.vehicleModel = v.ModelName;
            detail.vehicleYear = v.ModelYear;
            detail.vehicleColor = v.ExteriorColor;
            detail.vehicleMileage = v.LastOdometerReading;
        }

        if (assetId != null) {
            List<AssetWarranty> warranties = [
                SELECT Id, WarrantyType, StartDate, EndDate,
                       WarrantyTermId, WarrantyTerm.WarrantyTermName
                FROM AssetWarranty
                WHERE AssetId = :assetId
                  AND StartDate <= TODAY
                  AND EndDate >= TODAY
                ORDER BY EndDate DESC
                LIMIT 1
            ];
            if (warranties.isEmpty()) {
                warranties = [
                    SELECT Id, WarrantyType, StartDate, EndDate,
                           WarrantyTermId, WarrantyTerm.WarrantyTermName
                    FROM AssetWarranty
                    WHERE AssetId = :assetId
                      AND EndDate < TODAY
                    ORDER BY EndDate DESC
                    LIMIT 1
                ];
            }
            if (!warranties.isEmpty()) {
                AssetWarranty aw = warranties[0];
                detail.warrantyCoverage = aw.WarrantyTerm != null
                    ? aw.WarrantyTerm.WarrantyTermName
                    : aw.WarrantyType;
                detail.warrantyStartDate = aw.StartDate;
                detail.warrantyEndDate = aw.EndDate;
            }
        }

        return detail;
    }

    @AuraEnabled
    public static Map<String, Object> processClaimAction(String claimId, String action, String comments,
                                                          Decimal approvedAmount, String rejectionReason,
                                                          String rootCause, String correction) {
        // [v22.3] 3 C's enforcement at the LWC boundary. Engine stays permissive
        // (auto-approve flows can run without rootCause); only HUMAN approvals
        // routed through this controller require an explicit Cause.
        if ('Approve'.equals(action) && String.isBlank(rootCause)) {
            throw new AuraHandledException(
                'Root Cause is required when approving a claim. '
                + 'Briefly describe why the part failed (e.g. "Cell imbalance after thermal event").'
            );
        }
        WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
        inp.claimId = claimId;
        inp.action = action;
        inp.comments = comments;
        inp.rootCause = rootCause;
        inp.correction = correction;
        if (action == 'Reject') {
            inp.rejectionReason = String.isNotBlank(rejectionReason) ? rejectionReason : comments;
        }

        List<WC_ClaimDecision.Output> outputs = WC_ClaimDecision.processDecision(
            new List<WC_ClaimDecision.Input>{ inp }
        );

        if (action == 'Approve' && approvedAmount != null) {
            try {
                update new Claim(Id = claimId, ApprovedAmount = approvedAmount);
            } catch (Exception e) { /* non-blocking */ }
        }

        WC_ClaimDecision.Output out = outputs[0];
        return new Map<String, Object>{
            'success' => out.success,
            'claimNumber' => out.claimNumber,
            'newStatus' => out.newStatus,
            'message' => out.message
        };
    }

    @AuraEnabled
    public static Map<String, Object> processBatchAction(List<String> claimIds, String action, String comments) {
        List<WC_ClaimDecision.Input> inputs = new List<WC_ClaimDecision.Input>();
        for (String cId : claimIds) {
            WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
            inp.claimId = cId;
            inp.action = action;
            inp.comments = comments;
            if (action == 'Reject') {
                inp.rejectionReason = comments;
            }
            inputs.add(inp);
        }

        List<WC_ClaimDecision.Output> outputs = WC_ClaimDecision.processDecision(inputs);

        Integer successCount = 0;
        Integer failCount = 0;
        List<Map<String, Object>> resultList = new List<Map<String, Object>>();
        for (WC_ClaimDecision.Output out : outputs) {
            Map<String, Object> entry = new Map<String, Object>{
                'claimNumber' => out.claimNumber,
                'success' => out.success,
                'message' => out.message
            };
            resultList.add(entry);
            if (out.success) {
                successCount++;
            } else {
                failCount++;
            }
        }

        return new Map<String, Object>{
            'successCount' => successCount,
            'failCount' => failCount,
            'results' => resultList
        };
    }

    private static ClaimWrapper mapClaimToWrapper(Claim c, Datetime now) {
        ClaimWrapper w = new ClaimWrapper();
        w.id = c.Id;
        w.name = c.Name;
        w.status = c.Status;
        w.statusCode = c.StatusCode;
        w.severity = c.Severity;
        w.riskScore = c.Risk_Score__c != null ? Integer.valueOf(c.Risk_Score__c) : 0;
        w.riskLevel = getRiskLevel(c.Risk_Score__c);
        w.estimatedAmount = c.EstimatedAmount;
        w.approvedAmount = c.ApprovedAmount;
        w.dealerName = c.Account != null ? c.Account.Name : null;
        w.summary = c.Summary;
        w.aiRecommendation = c.AI_Recommendation__c;
        w.aiTriageNotes = c.AI_Triage_Notes__c;
        w.triageFlags = c.Triage_Flags__c;
        w.channel = c.Channel__c;
        w.initiationDate = c.InitiationDate;
        w.lastModifiedDate = c.LastModifiedDate;
        w.approverComments = c.Approver_Comments__c;
        w.dealerResponse   = c.Dealer_Response__c;
        w.riskCssClass = getRiskCssClass(w.riskLevel);
        w.statusCssClass = getStatusCssClass(c.Status);

        Boolean isPending = PENDING_STATUSES.contains(c.Status);
        if (isPending && c.InitiationDate != null) {
            Long hoursSince = getHoursSince(c.InitiationDate, now);
            w.slaHoursRemaining = Integer.valueOf(72 - hoursSince);
            w.slaCssClass = getSlaCssClass(hoursSince);
        } else {
            w.slaHoursRemaining = null;
            w.slaCssClass = '';
        }

        w.ownerId = c.OwnerId;
        w.ownerName = c.Owner != null ? c.Owner.Name : null;
        w.rowCssClass = buildRowCssClass(c.Status, w.riskLevel, w.slaCssClass);
        return w;
    }

    private static void copyBaseFields(Claim c, ClaimDetailWrapper d, Datetime now) {
        d.id = c.Id;
        d.name = c.Name;
        d.status = c.Status;
        d.statusCode = c.StatusCode;
        d.severity = c.Severity;
        d.riskScore = c.Risk_Score__c != null ? Integer.valueOf(c.Risk_Score__c) : 0;
        d.riskLevel = getRiskLevel(c.Risk_Score__c);
        d.estimatedAmount = c.EstimatedAmount;
        d.approvedAmount = c.ApprovedAmount;
        d.dealerName = c.Account != null ? c.Account.Name : null;
        d.summary = c.Summary;
        d.aiRecommendation = c.AI_Recommendation__c;
        d.aiTriageNotes = c.AI_Triage_Notes__c;
        d.channel = c.Channel__c;
        d.initiationDate = c.InitiationDate;
        d.lastModifiedDate = c.LastModifiedDate;
        d.finalizedDate = c.FinalizedDate;
        d.approverComments = c.Approver_Comments__c;
        d.approvedBy = c.ApprovedBy__r != null ? c.ApprovedBy__r.Name : null;
        d.rejectedBy = c.RejectedBy__r != null ? c.RejectedBy__r.Name : null;
        // [v22.4] Branded "Atlas AI Triage" attribution for auto-decided claims.
        d.decidedByName = WC_ClaimAttribution.decidedByDisplay(c);
        d.decidedByAutoTriage = WC_ClaimAttribution.isAutoTriage(c);
        d.approvalDate = c.ApprovalDate__c;
        d.rejectionReason = c.RejectionReason__c;
        d.mileageAtClaim = c.MileageAtClaim__c;
        d.diagnosticTroubleCode = c.DiagnosticTroubleCode__c;
        d.failureDescription = c.FailureDescription__c;
        d.dealerCode = c.DealerCode__c;
        d.repairOrderNumber = c.RepairOrderNumber__c;
        d.riskCssClass = getRiskCssClass(d.riskLevel);
        d.statusCssClass = getStatusCssClass(c.Status);

        Boolean isPending = PENDING_STATUSES.contains(c.Status);
        if (isPending && c.InitiationDate != null) {
            Long hoursSince = getHoursSince(c.InitiationDate, now);
            d.slaHoursRemaining = Integer.valueOf(72 - hoursSince);
            d.slaCssClass = getSlaCssClass(hoursSince);
        } else {
            d.slaHoursRemaining = null;
            d.slaCssClass = '';
        }

        d.rowCssClass = buildRowCssClass(c.Status, d.riskLevel, d.slaCssClass);
    }

    private static void attachRiskBreakdown(Claim c, ClaimDetailWrapper d) {
        d.riskBreakdownMethodology = c.Risk_Score_Methodology__c;
        d.riskBreakdownCalculatedAt = c.Risk_Score_Calculated_At__c;
        d.riskBreakdownConfidence = c.Risk_Score_Confidence__c;

        if (String.isNotBlank(c.Risk_Score_Breakdown__c)) {
            try {
                d.riskBreakdown = (RiskBreakdown) JSON.deserialize(c.Risk_Score_Breakdown__c, RiskBreakdown.class);
                return;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Electra Cars warranty: Risk_Score_Breakdown__c malformed for claim ' + c.Id + ': ' + e.getMessage());
            }
        }

        if (c.Risk_Score__c != null) {
            try {
                String fresh = WC_RiskBreakdownDeriver.deriveJson(c);
                d.riskBreakdown = (RiskBreakdown) JSON.deserialize(fresh, RiskBreakdown.class);
                if (d.riskBreakdownMethodology == null) {
                    d.riskBreakdownMethodology = WC_RiskBreakdownDeriver.METHODOLOGY;
                }
                if (d.riskBreakdownCalculatedAt == null) {
                    d.riskBreakdownCalculatedAt = Datetime.now();
                }
                if (d.riskBreakdownConfidence == null) {
                    d.riskBreakdownConfidence = WC_RiskBreakdownDeriver.computeConfidence(c);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Electra Cars warranty: lazy derive failed for claim ' + c.Id + ': ' + e.getMessage());
                d.riskBreakdown = null;
            }
        } else {
            d.riskBreakdown = null;
        }
    }

    private static String getRiskLevel(Decimal score) {
        if (score == null || score <= 30) return 'Low';
        if (score <= 60) return 'Medium';
        if (score <= 80) return 'High';
        return 'Critical';
    }

    private static String getRiskCssClass(String level) {
        switch on level {
            when 'Low'      { return 'risk-low'; }
            when 'Medium'   { return 'risk-medium'; }
            when 'High'     { return 'risk-high'; }
            when 'Critical' { return 'risk-critical'; }
            when else       { return 'risk-low'; }
        }
    }

    private static String getStatusCssClass(String status) {
        if (status == null) return 'status-new';
        switch on status {
            when 'Approved'             { return 'status-approved'; }
            when 'Denied'               { return 'status-denied'; }
            when 'Under Review'         { return 'status-review'; }
            when 'New'                  { return 'status-new'; }
            when 'Submitted'            { return 'status-submitted'; }
            when 'Requested Information'{ return 'status-info-requested'; }
            when else                   { return 'status-other'; }
        }
    }

    private static String getSlaCssClass(Long hoursSince) {
        if (hoursSince <= 48) return 'sla-ok';
        if (hoursSince <= 72) return 'sla-warn';
        return 'sla-breach';
    }

    private static Long getHoursSince(Datetime dt, Datetime now) {
        return dt.getTime() < now.getTime()
            ? (now.getTime() - dt.getTime()) / (1000 * 60 * 60)
            : 0;
    }

    private static String buildRowCssClass(String status, String riskLevel, String slaCss) {
        String css = '';
        if (status == 'Approved') {
            css = 'row-approved';
        } else if (status == 'Denied') {
            css = 'row-denied';
        } else {
            if (riskLevel == 'High' || riskLevel == 'Critical') {
                css = 'row-high-risk';
            }
            if (slaCss == 'sla-breach') {
                css += (String.isNotBlank(css) ? ' ' : '') + 'row-sla-breach';
            }
        }
        return css;
    }

    /* ── v9 · Conversation Log support ─────────────────────────────────── */

    /**
     * Returns the dealer-account contacts for a given claim — used by the
     * RequestInfo composer's @-mention picker so OEM can address a specific
     * dealer staffer instead of typing a name as free text.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getDealerContacts(String claimId) {
        if (String.isBlank(claimId)) return new List<Map<String, Object>>();
        List<Claim> rows = [SELECT AccountId FROM Claim WHERE Id = :claimId LIMIT 1];
        if (rows.isEmpty() || rows[0].AccountId == null) return new List<Map<String, Object>>();
        List<Contact> contacts = [
            SELECT Id, Name, Title, Email
            FROM Contact
            WHERE AccountId = :rows[0].AccountId
            ORDER BY Name
            LIMIT 25
        ];
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Contact ct : contacts) {
            out.add(new Map<String, Object>{
                'id'    => ct.Id,
                'name'  => ct.Name,
                'title' => ct.Title,
                'email' => ct.Email
            });
        }
        return out;
    }

    /**
     * Lists files attached to the Claim (ContentDocumentLink → ContentVersion).
     * Returns enough metadata for the LWC to render a download row per file.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getClaimAttachments(String claimId) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        if (String.isBlank(claimId)) return result;

        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :claimId
        ]) docIds.add(l.ContentDocumentId);
        if (docIds.isEmpty()) return result;

        for (ContentVersion cv : [
            SELECT Id, ContentDocumentId, Title, FileExtension, FileType,
                   ContentSize, CreatedDate, CreatedBy.Name
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true
            ORDER BY CreatedDate DESC
        ]) {
            result.add(new Map<String, Object>{
                'id'           => cv.Id,
                'documentId'   => cv.ContentDocumentId,
                'title'        => cv.Title,
                'extension'    => cv.FileExtension,
                'fileType'     => cv.FileType,
                'sizeBytes'    => cv.ContentSize,
                'sizeLabel'    => formatFileSize(cv.ContentSize),
                'uploadedAt'   => cv.CreatedDate,
                'uploadedBy'   => cv.CreatedBy != null ? cv.CreatedBy.Name : null,
                'downloadUrl'  => '/sfc/servlet.shepherd/version/download/' + cv.Id
            });
        }
        return result;
    }

    /**
     * OEM-side file attach. Files go on the Claim record (same place dealer
     * uploads land), and a system entry is appended to Conversation_Log__c so
     * the dealer's portal shows the OEM's reference docs in the same timeline.
     */
    @AuraEnabled
    public static Map<String, Object> attachOEMFiles(String claimId, List<WC_ClaimAttachmentService.FileInput> files) {
        if (String.isBlank(claimId) || files == null || files.isEmpty()) {
            return new Map<String, Object>{ 'success' => false, 'message' => 'Claim ID and files are required.' };
        }
        Map<String, Object> attachResult = WC_ClaimAttachmentService.attach(claimId, files);
        Integer attached = (Integer) attachResult.get('attachedCount');
        if (attached != null && attached > 0) {
            // Append a system-tagged conversation entry so the dealer sees what came in.
            Claim c = [SELECT Id, Conversation_Log__c FROM Claim WHERE Id = :claimId LIMIT 1];
            List<String> names = new List<String>();
            for (WC_ClaimAttachmentService.FileInput f : files) names.add(f.name);
            String body = '📎 ' + attached + ' file(s) attached: ' + String.join(names, ', ');
            c.Conversation_Log__c = ClaimConversationService.appendEntry(
                c.Conversation_Log__c, ClaimConversationService.ROLE_OEM, UserInfo.getName(), body);
            update c;
        }
        return attachResult;
    }

    /** Human-friendly file size: "12 KB", "3.4 MB", etc. */
    private static String formatFileSize(Integer bytes) {
        if (bytes == null) return '';
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return ((Decimal) bytes / 1024).setScale(0, System.RoundingMode.HALF_UP) + ' KB';
        return ((Decimal) bytes / (1024 * 1024)).setScale(1, System.RoundingMode.HALF_UP) + ' MB';
    }
}