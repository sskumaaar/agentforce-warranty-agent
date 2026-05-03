public with sharing class WC_ScheduleTestDrive {

    @InvocableMethod(
        label='Schedule Test Drive'
        description='Creates a Test_Drive__c record for a customer. Used when a warranty claim requires extended repair and the customer is offered a loaner or test drive of another Electra model.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        List<Test_Drive__c> drivesToInsert = new List<Test_Drive__c>();
        Map<Integer, Integer> driveIdxToOutputIdx = new Map<Integer, Integer>();

        for (Integer i = 0; i < inputs.size(); i++) {
            Input inp = inputs[i];
            Output out = new Output();
            outputs.add(out);

            if (String.isBlank(inp.customerName)) {
                out.success = false;
                out.message = 'Customer name is required to schedule a test drive';
                continue;
            }
            if (inp.preferredDate == null) {
                out.success = false;
                out.message = 'Preferred date is required to schedule a test drive';
                continue;
            }

            Test_Drive__c td = new Test_Drive__c();
            td.Test_Drive_Date_Time__c = Datetime.newInstance(
                inp.preferredDate.year(), inp.preferredDate.month(), inp.preferredDate.day(), 10, 0, 0
            );
            td.Model_Interested__c = String.isNotBlank(inp.vehicleModel) ? inp.vehicleModel : 'Any Electra Model';
            td.Status__c = 'Scheduled';

            if (String.isNotBlank(inp.contactPhone)) {
                try {
                    String digits = inp.contactPhone.replaceAll('[^0-9]', '');
                    if (digits.length() > 18) { digits = digits.substring(digits.length() - 18); }
                    td.Mobile_Number__c = Decimal.valueOf(digits);
                } catch (Exception e) {
                    // non-numeric phone — skip field
                }
            }

            Integer driveIdx = drivesToInsert.size();
            drivesToInsert.add(td);
            driveIdxToOutputIdx.put(driveIdx, i);
        }

        if (!drivesToInsert.isEmpty()) {
            List<Database.SaveResult> results = Database.insert(drivesToInsert, false);

            for (Integer j = 0; j < results.size(); j++) {
                Integer outIdx = driveIdxToOutputIdx.get(j);
                Output out = outputs[outIdx];
                Input inp = inputs[outIdx];

                if (results[j].isSuccess()) {
                    out.success = true;
                    out.testDriveId = drivesToInsert[j].Id;
                    out.message = 'Test drive scheduled for ' + inp.customerName
                        + ' on ' + inp.preferredDate.format()
                        + ' — model: ' + (String.isNotBlank(inp.vehicleModel) ? inp.vehicleModel : 'Any Electra Model');
                } else {
                    out.success = false;
                    out.message = 'Failed to schedule test drive: ' + results[j].getErrors()[0].getMessage();
                }
            }
        }

        return outputs;
    }

    /**
     * @AuraEnabled wrapper for LWC chat. Same logic as the InvocableMethod above, but
     * directly callable from JS without going through a Flow.
     */
    @AuraEnabled
    public static Map<String, Object> scheduleFromChat(String customerName, String vehicleModel,
                                                        String preferredDateIso, String contactPhone) {
        try {
            if (String.isBlank(customerName)) throw new AuraHandledException('Customer name is required');
            if (String.isBlank(preferredDateIso)) throw new AuraHandledException('Preferred date is required');
            Input inp = new Input();
            inp.customerName  = customerName;
            inp.preferredDate = Date.valueOf(preferredDateIso);
            inp.vehicleModel  = vehicleModel;
            inp.contactPhone  = contactPhone;
            List<Output> outs = execute(new List<Input>{ inp });
            if (outs.isEmpty()) throw new AuraHandledException('No result from scheduler');
            Output o = outs[0];
            return new Map<String, Object>{
                'success'      => o.success,
                'testDriveId'  => o.testDriveId,
                'message'      => o.message
            };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw new AuraHandledException('Schedule failed: ' + e.getMessage()); }
    }

    public class Input {
        @InvocableVariable(required=true label='Customer Name'
            description='Name of the customer requesting the test drive')
        public String customerName;

        @InvocableVariable(required=true label='Preferred Date'
            description='Preferred date for the test drive')
        public Date preferredDate;

        @InvocableVariable(label='Vehicle Model'
            description='Which Electra model to test drive (e.g. Electra Thunder)')
        public String vehicleModel;

        @InvocableVariable(label='Dealer Account Id'
            description='ID of the dealer facilitating the test drive')
        public String dealerAccountId;

        @InvocableVariable(label='Contact Phone'
            description='Customer phone number for confirmation')
        public String contactPhone;

        @InvocableVariable(label='Contact Email'
            description='Customer email for confirmation')
        public String contactEmail;

        @InvocableVariable(label='Related Claim Id'
            description='ID of the warranty claim that triggered this test drive offer')
        public String relatedClaimId;

        @InvocableVariable(label='Notes'
            description='Additional notes (e.g. loaner while car is being repaired)')
        public String notes;
    }

    public class Output {
        @InvocableVariable(label='Success' description='True if the test drive was scheduled successfully')
        public Boolean success;

        @InvocableVariable(label='Test Drive Id' description='Salesforce ID of the created Test_Drive__c record')
        public String testDriveId;

        @InvocableVariable(label='Message' description='Confirmation or error message')
        public String message;
    }
}