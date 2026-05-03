@IsTest
private class WC_ClaimApprovalCenterControllerTest {

    @TestSetup
    static void makeData() {
        Account dealer = new Account(Name = 'Bay Area Electra Motors');
        insert dealer;

        Datetime now = Datetime.now();

        List<Claim> claims = new List<Claim>{
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'Under Review',
                Risk_Score__c = 85,
                EstimatedAmount = 150000,
                Channel__c = 'Portal',
                InitiationDate = now.addDays(-4),
                Summary = 'Battery thermal runaway detected during fast-charging at Bay Area facility'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'Under Review',
                Risk_Score__c = 45,
                EstimatedAmount = 25000,
                Channel__c = 'WhatsApp',
                InitiationDate = now.addDays(-1),
                Summary = 'Regenerative brake controller intermittent failure during highway driving'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'Approved',
                Risk_Score__c = 15,
                EstimatedAmount = 8000,
                Channel__c = 'Portal',
                ApprovedBy__c = UserInfo.getUserId(),
                ApprovalDate__c = now,
                InitiationDate = now.addDays(-5),
                FinalizedDate = now,
                Summary = 'Standard tire rotation and alignment service under warranty'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'Denied',
                Risk_Score__c = 90,
                EstimatedAmount = 200000,
                Channel__c = 'Web_Chat',
                RejectedBy__c = UserInfo.getUserId(),
                InitiationDate = now.addDays(-10),
                FinalizedDate = now,
                Summary = 'Full drivetrain replacement requested — warranty voided by unauthorized modifications'
            ),
            new Claim(
                Name = WC_ClaimNameGenerator.next(),
                AccountId = dealer.Id,
                Status = 'New',
                Risk_Score__c = 55,
                EstimatedAmount = 35000,
                Channel__c = 'Email',
                InitiationDate = now,
                Summary = 'EV Battery Module Assembly showing degraded range after 18 months'
            )
        };
        insert claims;
    }

    @IsTest
    static void testGetApprovalDashboardData() {
        Map<String, Object> result = WC_ClaimApprovalCenterController.getApprovalDashboardData();

        List<Object> claims = (List<Object>) result.get('claims');
        System.assertEquals(5, claims.size(), 'Should return all 5 test claims');

        Map<String, Object> kpis = (Map<String, Object>) result.get('kpis');
        System.assertEquals(3, kpis.get('totalPending'), 'Under Review x2 + New x1 = 3 pending');
        System.assertEquals(5, kpis.get('totalClaims'), 'Total claims should be 5');

        Map<String, Integer> riskDist = (Map<String, Integer>) result.get('riskDistribution');
        System.assertNotEquals(null, riskDist.get('Low'), 'Risk distribution should have Low key');
        System.assertNotEquals(null, riskDist.get('Critical'), 'Risk distribution should have Critical key');

        Map<String, Integer> slaBuckets = (Map<String, Integer>) result.get('slaBuckets');
        System.assertNotEquals(null, slaBuckets, 'SLA buckets should not be null');
        Integer totalSlaBuckets = slaBuckets.get('within24h') + slaBuckets.get('within48h')
            + slaBuckets.get('within72h') + slaBuckets.get('breach');
        System.assertEquals(3, totalSlaBuckets, 'SLA buckets should account for all 3 pending claims');

        Map<String, Integer> statusDist = (Map<String, Integer>) result.get('statusDistribution');
        System.assert(statusDist.containsKey('Under Review'), 'Should have Under Review status');
        System.assert(statusDist.containsKey('Approved'), 'Should have Approved status');
    }

    @IsTest
    static void testGetClaimDetail() {
        Claim testClaim = [SELECT Id, Name FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 85 LIMIT 1];

        WC_ClaimApprovalCenterController.ClaimDetailWrapper detail =
            WC_ClaimApprovalCenterController.getClaimDetail(testClaim.Id);

        System.assertNotEquals(null, detail, 'Detail should not be null');
        System.assert(detail.name != null && detail.name.startsWith('WC-'), 'Name should follow WC- prefix');
        System.assertEquals('Under Review', detail.status, 'Status should be Under Review');
        System.assertEquals(85, detail.riskScore, 'Risk score should be 85');
        System.assertEquals('Critical', detail.riskLevel, 'Risk level should be Critical');
    }

    @IsTest
    static void testProcessClaimAction() {
        Claim testClaim = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 45 LIMIT 1];

        Test.startTest();
        Map<String, Object> result = WC_ClaimApprovalCenterController.processClaimAction(
            testClaim.Id, 'Approve',
            'Warranty coverage confirmed for Electra regenerative brake controller',
            25000, null,
            'Brake controller solenoid stuck under load',  // Cause (required for Approve)
            'Replace brake controller assembly P-BRAKE-EV-2025-019'  // Correction (optional)
        );
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'Approval should succeed');
        System.assertEquals('Approved', result.get('newStatus'), 'Status should be Approved');
    }

    @IsTest
    static void testProcessBatchAction() {
        List<Claim> testClaims = [SELECT Id FROM Claim WHERE Status = 'Under Review'];
        List<String> claimIds = new List<String>();
        for (Claim c : testClaims) {
            claimIds.add(c.Id);
        }

        Test.startTest();
        Map<String, Object> result = WC_ClaimApprovalCenterController.processBatchAction(
            claimIds, 'Approve', 'Batch approval — verified under Electra standard warranty terms'
        );
        Test.stopTest();

        System.assertEquals(2, result.get('successCount'), 'Both Under Review claims should be approved');
        System.assertEquals(0, result.get('failCount'), 'No failures expected');
    }

    @IsTest
    static void testProcessClaimActionApproveBlocksWithoutCause() {
        // [v22.3] Controller-level enforcement: Approve via the LWC must carry a
        // RootCause. Engine stays permissive (auto-approve flows can run blank).
        Claim testClaim = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 45 LIMIT 1];

        Boolean threw = false;
        String message = '';
        Test.startTest();
        try {
            WC_ClaimApprovalCenterController.processClaimAction(
                testClaim.Id, 'Approve',
                'Looks good',
                25000, null,
                null,  // Cause omitted — must throw
                null
            );
        } catch (AuraHandledException ahe) {
            threw = true;
            message = ahe.getMessage();
        }
        Test.stopTest();

        System.assert(threw, 'Approve without Cause must throw AuraHandledException');
    }

    @IsTest
    static void testProcessClaimActionReject() {
        Claim testClaim = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 85 LIMIT 1];

        Test.startTest();
        Map<String, Object> result = WC_ClaimApprovalCenterController.processClaimAction(
            testClaim.Id, 'Reject',
            'VIN inspection reveals unauthorized drivetrain modifications voiding Electra warranty',
            null,
            'VIN inspection reveals unauthorized drivetrain modifications voiding Electra warranty',
            null, null  // Cause/Correction not required for Reject
        );
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'Rejection should succeed');
        System.assertEquals('Denied', result.get('newStatus'), 'Status should be Denied');
    }

    @IsTest
    static void testProcessClaimActionRequestInfo() {
        Claim testClaim = [SELECT Id FROM Claim WHERE Status = 'New' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = WC_ClaimApprovalCenterController.processClaimAction(
            testClaim.Id, 'RequestInfo',
            'Dealer to provide Electra battery diagnostic report and VIN inspection photos',
            null, null,
            null, null  // Cause/Correction not required for RequestInfo
        );
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'RequestInfo should succeed');
        System.assertEquals('Requested Information', result.get('newStatus'), 'Status should be Requested Information');
    }

    @IsTest
    static void testGetClaimDetailInvalidId() {
        Boolean exceptionThrown = false;
        try {
            WC_ClaimApprovalCenterController.getClaimDetail(null);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw AuraHandledException for null ID');
    }

    @IsTest
    static void testCreateAndGetClaimComments() {
        Claim testClaim = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 85 LIMIT 1];

        Test.startTest();
        Map<String, Object> createResult = WC_ClaimApprovalCenterController.createClaimComment(
            testClaim.Id, '<p>Verified VIN data for Electra battery claim</p>', 'Santosh', 'General'
        );
        WC_ClaimApprovalCenterController.createClaimComment(
            testClaim.Id, '<p>@Piyush please check risk score</p>', 'Pooja', 'InternalNote'
        );
        Test.stopTest();

        System.assertEquals(true, createResult.get('success'), 'Comment creation should succeed');

        List<Map<String, Object>> comments = WC_ClaimApprovalCenterController.getClaimComments(testClaim.Id);
        System.assertEquals(2, comments.size(), 'Should return 2 comments');
        System.assertEquals('Santosh', comments[0].get('authorName'), 'First comment author should be Santosh');
        System.assertEquals('InternalNote', comments[1].get('commentType'), 'Second comment should be InternalNote');
    }

    @IsTest
    static void testCreateClaimCommentBlankBody() {
        Claim testClaim = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 85 LIMIT 1];
        Boolean exceptionThrown = false;
        try {
            WC_ClaimApprovalCenterController.createClaimComment(testClaim.Id, '', 'Santosh', 'General');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw for blank comment body');
    }

    @IsTest
    static void testGetClaimDetailWithBreakdown() {
        Claim seed = [SELECT Id FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 85 LIMIT 1];
        update new Claim(
            Id = seed.Id,
            Risk_Score_Breakdown__c = JSON.serialize(new Map<String, Object>{
                'version' => 'electra_triage_v1.0',
                'summary' => '2 factors flagged',
                'baseline' => 0,
                'totalContribution' => 85,
                'factors' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'name' => 'Mileage vs Warranty Limit',
                        'value' => 'High mileage at claim',
                        'weight' => 0.25,
                        'contribution' => 22,
                        'verdict' => 'fail',
                        'reference' => 'WarrantyTerm.UsageCovered'
                    },
                    new Map<String, Object>{
                        'name' => 'Claim Amount',
                        'value' => 'Above-typical exposure',
                        'weight' => 0.20,
                        'contribution' => 18,
                        'verdict' => 'fail',
                        'reference' => 'Claim.EstimatedAmount'
                    }
                }
            }),
            Risk_Score_Methodology__c = 'electra_triage_v1.0',
            Risk_Score_Calculated_At__c = Datetime.now(),
            Risk_Score_Confidence__c = 87.50
        );

        Test.startTest();
        WC_ClaimApprovalCenterController.ClaimDetailWrapper detail =
            WC_ClaimApprovalCenterController.getClaimDetail(seed.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail.riskBreakdown, 'Breakdown should be parsed and attached');
        System.assertEquals(2, detail.riskBreakdown.factors.size(), 'Should have 2 factors');
        System.assertEquals('electra_triage_v1.0', detail.riskBreakdownMethodology);
        System.assertEquals(87.50, detail.riskBreakdownConfidence);
        System.assertNotEquals(null, detail.riskBreakdownCalculatedAt);
    }

    @IsTest
    static void testGetClaimDetailLazyDeriveOnMissingBreakdown() {
        Claim seed = [SELECT Id, Risk_Score__c FROM Claim WHERE Status = 'Under Review' AND Risk_Score__c = 45 LIMIT 1];

        Test.startTest();
        WC_ClaimApprovalCenterController.ClaimDetailWrapper detail =
            WC_ClaimApprovalCenterController.getClaimDetail(seed.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail.riskBreakdown,
            'Lazy derive should populate breakdown when stored JSON is missing but score exists');
        System.assertEquals(WC_RiskBreakdownDeriver.METHODOLOGY, detail.riskBreakdownMethodology,
            'Methodology should fall through to current deriver version');
        System.assertNotEquals(null, detail.riskBreakdownConfidence,
            'Confidence should be computed on the fly');
    }

    @IsTest
    static void testGetClaimDetailMalformedBreakdownFallsThroughToLazyDerive() {
        Claim seed = [SELECT Id, Risk_Score__c FROM Claim WHERE Status = 'Approved' LIMIT 1];
        update new Claim(Id = seed.Id, Risk_Score_Breakdown__c = '{this is not valid JSON');

        Test.startTest();
        WC_ClaimApprovalCenterController.ClaimDetailWrapper detail =
            WC_ClaimApprovalCenterController.getClaimDetail(seed.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail, 'Wrapper should still return');
        System.assertNotEquals(null, detail.riskBreakdown,
            'After malformed JSON fails, lazy derive should populate breakdown');
    }

    @IsTest
    static void testGetClaimDetailNoScoreNoBreakdown() {
        Claim seed = [SELECT Id FROM Claim WHERE Status = 'New' LIMIT 1];
        update new Claim(Id = seed.Id, Risk_Score__c = null, Risk_Score_Breakdown__c = null,
                         Risk_Score_Methodology__c = null);

        Test.startTest();
        WC_ClaimApprovalCenterController.ClaimDetailWrapper detail =
            WC_ClaimApprovalCenterController.getClaimDetail(seed.Id);
        Test.stopTest();

        System.assertEquals(null, detail.riskBreakdown,
            'Claims with no Risk_Score__c should not trigger lazy derive');
    }
}