public with sharing class WC_DealerDashboardController {

    @TestVisible private static Id mockDealerAccountId = null;

    private static Id getDealerAccountId() {
        if (Test.isRunningTest() && mockDealerAccountId != null) { return mockDealerAccountId; }
        Id userId = UserInfo.getUserId();
        List<User> users = [SELECT ContactId, AccountId FROM User WHERE Id = :userId LIMIT 1];
        if (users.isEmpty()) return null;
        if (users[0].AccountId != null) return users[0].AccountId;
        if (users[0].ContactId != null) {
            List<Contact> contacts = [SELECT AccountId FROM Contact WHERE Id = :users[0].ContactId LIMIT 1];
            if (!contacts.isEmpty() && contacts[0].AccountId != null) return contacts[0].AccountId;
        }
        return null;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getMyClaimSummary() {
        Id dealerAccountId = getDealerAccountId();

        List<AggregateResult> results;
        if (dealerAccountId != null) {
            results = [
                SELECT Status, COUNT(Id) cnt, SUM(EstimatedAmount) total
                FROM Claim
                WHERE AccountId = :dealerAccountId
                GROUP BY Status
            ];
        } else {
            results = [
                SELECT Status, COUNT(Id) cnt, SUM(EstimatedAmount) total
                FROM Claim
                GROUP BY Status
            ];
        }

        Map<String, Integer> statusCounts = new Map<String, Integer>();
        Map<String, Decimal> statusAmounts = new Map<String, Decimal>();
        Integer totalClaims = 0;
        Decimal totalAmount = 0;

        for (AggregateResult ar : results) {
            String status = (String) ar.get('Status');
            Integer cnt = (Integer) ar.get('cnt');
            Decimal amt = ar.get('total') != null ? (Decimal) ar.get('total') : 0;

            statusCounts.put(status, cnt);
            statusAmounts.put(status, amt);
            totalClaims += cnt;
            totalAmount += amt;
        }

        return new Map<String, Object>{
            'statusCounts' => statusCounts,
            'statusAmounts' => statusAmounts,
            'totalClaims' => totalClaims,
            'totalAmount' => totalAmount
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Claim> getRecentClaims() {
        Id dealerAccountId = getDealerAccountId();

        if (dealerAccountId != null) {
            return [
                SELECT Id, Name, Status, Summary, EstimatedAmount,
                       Risk_Score__c, InitiationDate, AI_Recommendation__c, Channel__c
                FROM Claim
                WHERE AccountId = :dealerAccountId
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        }
        return [
            SELECT Id, Name, Status, Summary, EstimatedAmount,
                   Risk_Score__c, InitiationDate, AI_Recommendation__c, Channel__c
            FROM Claim
            ORDER BY LastModifiedDate DESC
            LIMIT 10
        ];
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getWarrantyCoverage() {
        Id dealerAccountId = getDealerAccountId();

        if (dealerAccountId == null) {
            return new Map<String, Object>{
                'activeCount' => 0,
                'expiredCount' => 0,
                'totalCount' => 0
            };
        }

        List<Asset> assets = [SELECT Id FROM Asset WHERE AccountId = :dealerAccountId];
        if (assets.isEmpty()) {
            return new Map<String, Object>{
                'activeCount' => 0,
                'expiredCount' => 0,
                'totalCount' => 0
            };
        }

        Set<Id> assetIds = new Set<Id>();
        for (Asset a : assets) {
            assetIds.add(a.Id);
        }

        Integer activeCount = [
            SELECT COUNT()
            FROM AssetWarranty
            WHERE AssetId IN :assetIds
              AND StartDate <= TODAY
              AND EndDate >= TODAY
        ];

        Integer expiredCount = [
            SELECT COUNT()
            FROM AssetWarranty
            WHERE AssetId IN :assetIds
              AND EndDate < TODAY
        ];

        return new Map<String, Object>{
            'activeCount' => activeCount,
            'expiredCount' => expiredCount,
            'totalCount' => activeCount + expiredCount
        };
    }
}