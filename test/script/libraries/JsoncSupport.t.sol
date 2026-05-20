// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeploymentConfig} from "script/base/DeploymentConfig.sol";
import {JsoncLib} from "script/libraries/JsoncLib.sol";

contract JsoncConfigHarness is DeploymentConfig {
    string internal _path;

    constructor(string memory path) {
        _path = path;
    }

    function _configPath() internal view override returns (string memory) {
        return _path;
    }

    /// The base impl honors `JSONC_PRESTRIPPED` so CI can skip the Solidity stripper after a
    /// pre-strip step. These tests exist to verify the stripper itself, so the harness ignores
    /// the env flag and always strips.
    function _readConfig() internal view override returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return JsoncLib.stripComments(vm.readFile(_path));
    }

    function configString(string memory key) external view returns (string memory) {
        return _configString(key);
    }

    function configUint(string memory key) external view returns (uint256) {
        return _configUint(key);
    }
}

contract JsoncSupportTest is Test {
    string internal constant FIXTURE_LINE_COMMENTS_JSONC = "test/resources/jsonc/fixture.jsonc";
    string internal constant FIXTURE_LINE_COMMENTS_JSON = "test/resources/jsonc/fixture-comments.json";
    string internal constant FIXTURE_BLOCK_COMMENTS_JSONC = "test/resources/jsonc/fixture-block-comments.jsonc";

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // stripComments — direct unit tests on the pure stripper
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_stripComments_passesThroughInputWithoutComments() public pure {
        string memory input = '{"key": "value", "n": 1}';
        assertEq(JsoncLib.stripComments(input), input);
    }

    function test_stripComments_removesLineComment() public pure {
        assertEq(JsoncLib.stripComments("a // trailing\nb"), "a \nb");
    }

    function test_stripComments_removesLineCommentAtEofWithoutNewline() public pure {
        assertEq(JsoncLib.stripComments("a // trailing"), "a ");
    }

    function test_stripComments_removesSingleLineBlockComment() public pure {
        assertEq(JsoncLib.stripComments("a /* block */ b"), "a  b");
    }

    function test_stripComments_preservesNewlinesInsideBlockComment() public pure {
        // Line numbers must be preserved so JSON parser errors point at the right line.
        assertEq(JsoncLib.stripComments("a /* one\ntwo\nthree */ b"), "a \n\n b");
    }

    function test_stripComments_preservesLineCommentMarkerInsideString() public pure {
        string memory input = '"https://x.com/a//b"';
        assertEq(JsoncLib.stripComments(input), input);
    }

    function test_stripComments_preservesBlockCommentMarkerInsideString() public pure {
        string memory input = '"a/*not a comment*/b"';
        assertEq(JsoncLib.stripComments(input), input);
    }

    function test_stripComments_handlesEscapedQuoteInsideString() public pure {
        // The `\"` must not terminate the string, otherwise the trailing `//` would be misread
        // as a comment.
        string memory input = '"a\\"b//still in string"';
        assertEq(JsoncLib.stripComments(input), input);
    }

    function test_stripComments_handlesMixedCommentKinds() public pure {
        assertEq(JsoncLib.stripComments("a // line\nb /* block */ c"), "a \nb  c");
    }

    function test_stripComments_handlesEmptyInput() public pure {
        assertEq(JsoncLib.stripComments(""), "");
    }

    function test_stripComments_handlesLoneSlashOutsideComment() public pure {
        // A `/` not followed by `/` or `*` is just a literal slash.
        string memory input = "a / b";
        assertEq(JsoncLib.stripComments(input), input);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // configReader — integration tests via the harness (which forces stripping regardless of env)
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_configReader_allowsJsoncLineComments() public {
        JsoncConfigHarness config = new JsoncConfigHarness(FIXTURE_LINE_COMMENTS_JSONC);

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
        assertEq(config.configString(".nested.key"), "hello");
        assertEq(config.configString(".url"), "https://example.com/a//b");
    }

    function test_configReader_allowsCommentsInJsonFile() public {
        JsoncConfigHarness config = new JsoncConfigHarness(FIXTURE_LINE_COMMENTS_JSON);

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
    }

    function test_configReader_allowsBlockComments() public {
        JsoncConfigHarness config = new JsoncConfigHarness(FIXTURE_BLOCK_COMMENTS_JSONC);

        assertEq(config.configString(".name"), "test");
        assertEq(config.configUint(".value"), 42);
        assertEq(config.configString(".nested.key"), "hello");
        assertEq(config.configString(".url"), "https://example.com/a/*b*/c");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // read — env-var dispatch (JSONC_PRESTRIPPED)
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /// Foundry isolates `setEnv` mutations per test (rolled back at the test boundary), so the
    /// two env scenarios are exercised inside a single test function — across tests the env
    /// reverts to whatever the forge process started with.
    function test_read_dispatchesByPrestrippedFlag() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory raw = vm.readFile(FIXTURE_LINE_COMMENTS_JSON);
        string memory stripped = JsoncLib.stripComments(raw);

        vm.setEnv("JSONC_PRESTRIPPED", "true");
        assertEq(JsoncLib.read(FIXTURE_LINE_COMMENTS_JSON), raw, "prestripped=true: should return raw");

        vm.setEnv("JSONC_PRESTRIPPED", "false");
        assertEq(JsoncLib.read(FIXTURE_LINE_COMMENTS_JSON), stripped, "prestripped=false: should strip");
    }
}
