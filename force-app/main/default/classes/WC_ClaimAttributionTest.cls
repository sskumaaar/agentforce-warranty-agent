@IsTest
private class WC_ClaimAttributionTest {

    @IsTest
    static void autoApprovedReturnsAITriageLabel() {
        Account a = new Account(Name = 'AttrTest Dealer');
        insert a;
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = a.Id,
            Status = 'Approved'
            // ApprovedBy__c intentionally null → auto-decided
        );
        insert c;
        Claim refreshed = [SELECT Id, Status, ApprovedBy__c, ApprovedBy__r.Name,
                                  RejectedBy__c, RejectedBy__r.Name
                           FROM Claim WHERE Id = :c.Id];

        System.assertEquals('Atlas AI Triage',
            WC_ClaimAttribution.decidedByDisplay(refreshed),
            'Auto-approved (null ApprovedBy) must show the AI triage label');
        System.assertEquals(true, WC_ClaimAttribution.isAutoTriage(refreshed),
            'isAutoTriage true when no human is stamped');
    }

    @IsTest
    static void manualApprovedReturnsUserName() {
        Account a = new Account(Name = 'AttrTest Dealer 2');
        insert a;
        Id meId = UserInfo.getUserId();
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = a.Id,
            Status = 'Approved',
            ApprovedBy__c = meId
        );
        insert c;
        Claim refreshed = [SELECT Id, Status, ApprovedBy__c, ApprovedBy__r.Name,
                                  RejectedBy__c, RejectedBy__r.Name
                           FROM Claim WHERE Id = :c.Id];

        String me = [SELECT Name FROM User WHERE Id = :meId].Name;
        System.assertEquals(me,
            WC_ClaimAttribution.decidedByDisplay(refreshed),
            'Manually approved claim must show the actual user name');
        System.assertEquals(false, WC_ClaimAttribution.isAutoTriage(refreshed),
            'isAutoTriage false when a real user stamped it');
    }

    @IsTest
    static void openClaimReturnsNull() {
        Account a = new Account(Name = 'AttrTest Dealer 3');
        insert a;
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = a.Id,
            Status = 'New'
        );
        insert c;
        Claim refreshed = [SELECT Id, Status, ApprovedBy__c, ApprovedBy__r.Name,
                                  RejectedBy__c, RejectedBy__r.Name
                           FROM Claim WHERE Id = :c.Id];

        System.assertEquals(null,
            WC_ClaimAttribution.decidedByDisplay(refreshed),
            'Open claim has no decision attribution');
        System.assertEquals(false, WC_ClaimAttribution.isAutoTriage(refreshed));
    }

    @IsTest
    static void autoDeniedReturnsAITriageLabel() {
        Account a = new Account(Name = 'AttrTest Dealer 4');
        insert a;
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = a.Id,
            Status = 'Denied'
            // RejectedBy__c null → auto-denied
        );
        insert c;
        Claim refreshed = [SELECT Id, Status, ApprovedBy__c, ApprovedBy__r.Name,
                                  RejectedBy__c, RejectedBy__r.Name
                           FROM Claim WHERE Id = :c.Id];

        System.assertEquals('Atlas AI Triage',
            WC_ClaimAttribution.decidedByDisplay(refreshed));
        System.assertEquals(true, WC_ClaimAttribution.isAutoTriage(refreshed));
    }

    @IsTest
    static void nullClaimSafe() {
        System.assertEquals(null, WC_ClaimAttribution.decidedByDisplay(null));
        System.assertEquals(false, WC_ClaimAttribution.isAutoTriage(null));
    }

    @IsTest
    static void claimWithoutLookupQueryFallsBackToAILabel() {
        // Caller forgot to SELECT ApprovedBy__r.Name. We must NOT throw — we
        // fall back to AI label since the relationship isn't reachable.
        Account a = new Account(Name = 'AttrTest Dealer 5');
        insert a;
        Claim c = new Claim(
            Name = WC_ClaimNameGenerator.next(),
            AccountId = a.Id,
            Status = 'Approved',
            ApprovedBy__c = UserInfo.getUserId()
        );
        insert c;
        // Query without the relationship traversal
        Claim partial = [SELECT Id, Status, ApprovedBy__c, RejectedBy__c FROM Claim WHERE Id = :c.Id];
        // Should still produce a defined display (falls back to AI label)
        String display = WC_ClaimAttribution.decidedByDisplay(partial);
        System.assertEquals('Atlas AI Triage', display,
            'Without the User lookup queried, attribution helper falls back to AI label rather than throwing');
    }
}