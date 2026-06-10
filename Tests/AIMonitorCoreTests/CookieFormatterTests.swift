import Testing
@testable import AIMonitorCore

struct CookieFormatterTests {
    @Test func convertsExportedCookieJSONToHeader() {
        let input = """
        cookies:[
          {"name":"userId","value":"37013456"},
          {"name":"api-platform_serviceToken","value":"\\"secret\\""}
        ]
        """

        let header = CookieFormatter.header(from: input)

        #expect(header == "userId=37013456; api-platform_serviceToken=\"secret\"")
    }

    @Test func keepsRawCookieHeader() {
        let header = CookieFormatter.header(from: "a=1; b=2")

        #expect(header == "a=1; b=2")
    }
}
