public with sharing class POC_HelloPrim {

    @InvocableMethod(
        label='POC Hello Primitive'
        description='Returns a friendly greeting using primitive String input. Trigger utterances: say hello, say hi to <name>, greet me. Always pass a name string.'
    )
    public static List<String> hello(List<String> names) {
        List<String> results = new List<String>();
        for (String n : names) {
            String name = String.isBlank(n) ? 'World' : n;
            results.add('Hello, ' + name + '! POC primitive action just fired at ' + Datetime.now().format());
        }
        return results;
    }
}