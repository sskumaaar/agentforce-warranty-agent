public with sharing class WC_ApproverDashboardController {

    public class ClaimWrapper {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Integer riskScore;
        @AuraEnabled public String riskLevel;
        @AuraEnabled public String riskIcon;
        @AuraEnabled public Decimal estimatedAmount;
        @AuraEnabled public String dealerName;
        @AuraEnabled public String aiRecommendation;
        @AuraEnabled public String summary;
        @AuraEnabled public Datetime initiationDate;
        @AuraEnabled public String channel;
        @AuraEnabled public String severity;
    }

    @AuraEnabled(cacheable=true)
    public static List<ClaimWrapper> getPendingClaims() {
        List<ClaimWrapper> wrappers = new List<ClaimWrapper>();
        for (Claim c : [
            SELECT Id, Name, Status, Severity, Summary, EstimatedAmount,
                   AccountId, Account.Name, InitiationDate,
                   Risk_Score__c, AI_Recommendation__c, Channel__c
            FROM Claim
            WHERE Status IN ('New', 'Under Review', 'Submitted')
            ORDER BY Risk_Score__c DESC NULLS LAST, InitiationDate ASC
            LIMIT 100
        ]) {
            ClaimWrapper w = new ClaimWrapper();
            w.id = c.Id;
            w.name = c.Name;
            w.status = c.Status;
            w.severity = c.Severity;
            w.summary = c.Summary;
            w.estimatedAmount = c.EstimatedAmount;
            w.dealerName = c.Account?.Name;
            w.initiationDate = c.InitiationDate;
            w.aiRecommendation = c.AI_Recommendation__c;
            w.channel = c.Channel__c;

            Integer score = (c.Risk_Score__c != null) ? Integer.valueOf(c.Risk_Score__c) : null;
            w.riskScore = score;
            assignRiskLevel(w, score);

            wrappers.add(w);
        }
        return wrappers;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Integer> getStatusDistribution() {
        Map<String, Integer> dist = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Status, COUNT(Id) cnt FROM Claim GROUP BY Status
        ]) {
            dist.put((String) ar.get('Status'), (Integer) ar.get('cnt'));
        }
        return dist;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Integer> getRiskDistribution() {
        Map<String, Integer> buckets = new Map<String, Integer>{
            'Low' => 0, 'Medium' => 0, 'High' => 0, 'Critical' => 0
        };
        for (Claim c : [
            SELECT Risk_Score__c FROM Claim WHERE Risk_Score__c != null
        ]) {
            Integer score = Integer.valueOf(c.Risk_Score__c);
            if (score <= 30) {
                buckets.put('Low', buckets.get('Low') + 1);
            } else if (score <= 60) {
                buckets.put('Medium', buckets.get('Medium') + 1);
            } else if (score <= 80) {
                buckets.put('High', buckets.get('High') + 1);
            } else {
                buckets.put('Critical', buckets.get('Critical') + 1);
            }
        }
        return buckets;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Integer> getTodayActions() {
        Map<String, Integer> actions = new Map<String, Integer>{
            'approvedToday' => 0, 'deniedToday' => 0
        };
        for (AggregateResult ar : [
            SELECT Status, COUNT(Id) cnt
            FROM Claim
            WHERE LastModifiedDate = TODAY AND Status IN ('Approved', 'Denied')
            GROUP BY Status
        ]) {
            String status = (String) ar.get('Status');
            Integer cnt = (Integer) ar.get('cnt');
            if (status == 'Approved') {
                actions.put('approvedToday', cnt);
            } else if (status == 'Denied') {
                actions.put('deniedToday', cnt);
            }
        }
        return actions;
    }

    @AuraEnabled
    public static Map<String, Object> processClaimDecision(String claimId, String action, String comments) {
        Map<String, Object> result = new Map<String, Object>();
        try {
            WC_ClaimDecision.Input inp = new WC_ClaimDecision.Input();
            inp.claimId = claimId;
            inp.action = action;
            inp.comments = comments;
            if (action == 'Reject') {
                inp.rejectionReason = comments;
            }

            List<WC_ClaimDecision.Output> outputs = WC_ClaimDecision.processDecision(
                new List<WC_ClaimDecision.Input>{ inp }
            );

            WC_ClaimDecision.Output out = outputs[0];
            result.put('success', out.success);
            result.put('claimNumber', out.claimNumber);
            result.put('newStatus', out.newStatus);
            result.put('message', out.message);
        } catch (Exception e) {
            result.put('success', false);
            result.put('message', 'Error processing claim decision: ' + e.getMessage());
        }
        return result;
    }

    private static void assignRiskLevel(ClaimWrapper w, Integer score) {
        if (score == null) {
            w.riskLevel = 'Unknown';
            w.riskIcon = 'utility:question';
        } else if (score <= 30) {
            w.riskLevel = 'Low';
            w.riskIcon = 'utility:check';
        } else if (score <= 60) {
            w.riskLevel = 'Medium';
            w.riskIcon = 'utility:warning';
        } else if (score <= 80) {
            w.riskLevel = 'High';
            w.riskIcon = 'utility:error';
        } else {
            w.riskLevel = 'Critical';
            w.riskIcon = 'utility:ban';
        }
    }
}