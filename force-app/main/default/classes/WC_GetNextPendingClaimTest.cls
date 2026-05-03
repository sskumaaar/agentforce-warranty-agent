@IsTest
private class WC_GetNextPendingClaimTest {

    @TestSetup
    static void setup() {
        Account d = new Account(Name = 'NextClaim Test Dealer');
        insert d;
        List<Claim> claims = new List<Claim>{
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = d.Id, Status = 'New', Summary = 'High risk',
                EstimatedAmount = 500, InitiationDate = Date.today(),
                Risk_Score__c = 90, AI_Recommendation__c = 'Investigate',
                AI_Triage_Notes__c = 'Critical part — investigate.',
                Channel__c = 'Web_Chat', DealerCode__c = 'DLR-NXT'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = d.Id, Status = 'Submitted', Summary = 'Medium risk',
                EstimatedAmount = 200, InitiationDate = Date.today().addDays(-5),
                Risk_Score__c = 50, AI_Recommendation__c = 'Review',
                Channel__c = 'Portal', DealerCode__c = 'DLR-NXT'
            )
        };
        insert claims;
    }

    @IsTest
    static void testRiskMode_default() {
        WC_GetNextPendingClaim.Input inp = new WC_GetNextPendingClaim.Input();
        Test.startTest();
        List<WC_GetNextPendingClaim.Output> r = WC_GetNextPendingClaim.getNext(new List<WC_GetNextPendingClaim.Input>{ inp });
        Test.stopTest();
        System.assert(r[0].found);
        System.assertEquals(90, r[0].riskScore.intValue(), 'Highest risk should be returned first');
        System.assertEquals('Investigate', r[0].aiRecommendation);
        System.assertNotEquals(null, r[0].aiTriageNotes);
    }

    @IsTest
    static void testAgingMode() {
        WC_GetNextPendingClaim.Input inp = new WC_GetNextPendingClaim.Input();
        inp.sortMode = 'aging';
        Test.startTest();
        List<WC_GetNextPendingClaim.Output> r = WC_GetNextPendingClaim.getNext(new List<WC_GetNextPendingClaim.Input>{ inp });
        Test.stopTest();
        System.assert(r[0].found);
        System.assert(r[0].daysPending >= 5, 'Oldest pending should win in aging mode');
    }

    @IsTest
    static void testSkipList() {
        Claim highRisk = [SELECT Name FROM Claim WHERE Risk_Score__c = 90 LIMIT 1];
        WC_GetNextPendingClaim.Input inp = new WC_GetNextPendingClaim.Input();
        inp.skipClaimNumbers = highRisk.Name;
        Test.startTest();
        List<WC_GetNextPendingClaim.Output> r = WC_GetNextPendingClaim.getNext(new List<WC_GetNextPendingClaim.Input>{ inp });
        Test.stopTest();
        System.assert(r[0].found);
        System.assertNotEquals(highRisk.Name, r[0].claimNumber, 'Skipped claim must not be returned');
    }

    @IsTest
    static void testQueueExhausted() {
        delete [SELECT Id FROM Claim];
        WC_GetNextPendingClaim.Input inp = new WC_GetNextPendingClaim.Input();
        Test.startTest();
        List<WC_GetNextPendingClaim.Output> r = WC_GetNextPendingClaim.getNext(new List<WC_GetNextPendingClaim.Input>{ inp });
        Test.stopTest();
        System.assertEquals(false, r[0].found);
        System.assert(r[0].message.contains('No more'));
    }

    @IsTest
    static void testEmptyInputList() {
        Test.startTest();
        List<WC_GetNextPendingClaim.Output> r = WC_GetNextPendingClaim.getNext(new List<WC_GetNextPendingClaim.Input>());
        Test.stopTest();
        System.assertEquals(1, r.size(), 'Empty input list should still produce one default response');
    }
}