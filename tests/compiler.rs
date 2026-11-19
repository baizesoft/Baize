use std::{
    fs,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};
fn run(source: &str) -> (bool, String) {
    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("baize-test-{id}"));
    fs::create_dir_all(&dir).unwrap();
    let src = dir.join("program.bz");
    let out = dir.join("program.c");
    fs::write(&src, source).unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_bzseed"))
        .arg(src)
        .arg(&out)
        .output()
        .unwrap();
    let text = if result.status.success() {
        fs::read_to_string(out).unwrap()
    } else {
        String::from_utf8(result.stderr).unwrap()
    };
    let _ = fs::remove_dir_all(dir);
    (result.status.success(), text)
}
const OUT: &str = "\u{8f93}\u{51fa}";
const HELLO: &str = "\u{4f60}\u{597d}\u{ff0c}\u{767d}\u{6cfd}\u{ff01}";
#[test]
fn chinese_and_ascii_string_delimiters_emit_stable_utf8_bytes() {
    let src = format!(
        "{}\u{ff08}\u{201c}{}\u{201d}\u{ff09}\n{}\u{ff08}\"second\"\u{ff09}\n",
        OUT, HELLO, OUT
    );
    let (ok, c) = run(&src);
    assert!(ok, "{c}");
    assert!(c.contains("228,189,160,229,165,189"));
    assert_eq!(c.matches("fwrite(s, 1, sizeof s, stdout)").count(), 2);
    assert_eq!(run(&src).1, run(&src).1);
}
#[test]
fn malformed_chinese_syntax_is_rejected_in_chinese() {
    let src = format!("{}\u{ff08}\u{201c}\u{672a}\u{95ed}\u{5408}\u{ff09}\n", OUT);
    let (ok, diagnostic) = run(&src);
    assert!(!ok);
    assert!(
        diagnostic.contains("\u{7f16}\u{8bd1}\u{9519}\u{8bef}")
            && diagnostic.contains("\u{672a}\u{95ed}\u{5408}"),
        "{diagnostic}"
    );
}
#[test]
fn changed_source_changes_generated_program() {
    let a = format!("{}\u{ff08}\u{201c}\u{7532}\u{201d}\u{ff09}\n", OUT);
    let b = format!("{}\u{ff08}\u{201c}\u{4e59}\u{201d}\u{ff09}\n", OUT);
    assert_ne!(run(&a).1, run(&b).1);
}
#[test]
fn integer_variables_and_precedence_are_compiled() {
    let src = "\u{6574}\u{6570} \u{6570}\u{91cf} = 2 + 3 * 4\u{ff1b}\n\u{8f93}\u{51fa}\u{ff08}\u{6570}\u{91cf}\u{ff09}\n";
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    assert!(c.contains("(2 + (3 * 4))"));
    assert!(c.contains("int64_t v_"));
}
#[test]
fn recursive_function_and_while_control_flow_are_compiled() {
    let src = concat!(
        "\u{51fd}\u{6570} \u{6c42}\u{548c}(\u{4e0a}\u{9650}) {\n",
        "\u{6574}\u{6570} \u{7ed3}\u{679c} = 0\n",
        "\u{6574}\u{6570} \u{7d22}\u{5f15} = 0\n",
        "\u{5f53}(\u{7d22}\u{5f15} < \u{4e0a}\u{9650}) {\n",
        "\u{7ed3}\u{679c} = \u{7ed3}\u{679c} + \u{7d22}\u{5f15}\n",
        "\u{7d22}\u{5f15} = \u{7d22}\u{5f15} + 1\n",
        "}\n\u{8fd4}\u{56de} \u{7ed3}\u{679c}\n}\n",
        "\u{8f93}\u{51fa}(\u{6c42}\u{548c}(5))\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    assert!(c.contains("while ("));
    assert!(c.contains("static int64_t"));
    assert!(c.contains("return v_"));
}
#[test]
fn recursive_calls_and_if_else_are_emitted() {
    let src = concat!(
        "\u{51fd}\u{6570} \u{9636}\u{4e58}(\u{6570}) {\n",
        "\u{5982}\u{679c}(\u{6570} <= 1) {\n\u{8fd4}\u{56de} 1\n}",
        " \u{5426}\u{5219} {\n\u{8fd4}\u{56de} \u{6570} * \u{9636}\u{4e58}(\u{6570} - 1)\n}\n}\n",
        "\u{8f93}\u{51fa}(\u{9636}\u{4e58}(5))\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    assert!(c.contains("if ("));
    assert!(c.contains("else {"));
    assert!(c.contains("* v_e9_98_b6_e4_b9_98"), "{c}");
    assert_eq!(c.matches("return 0;").count(), 1);
}
#[test]
fn fixed_byte_arrays_support_index_read_and_write() {
    let src = concat!(
        "\u{5b57}\u{8282}\u{6570}\u{7ec4} \u{7f13}\u{51b2}[8]\n",
        "\u{7f13}\u{51b2}[0] = 65\n",
        "\u{8f93}\u{51fa}(\u{7f13}\u{51b2}[0])\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    assert!(c.contains("unsigned char v_"));
    assert!(c.contains("[0] = (unsigned char)(65)"));
    assert!(c.contains("(long long)(v_"));
}
#[test]
fn file_read_write_apis_compile_without_embedding_compiler_logic_in_runtime() {
    let src = concat!(
        "\u{5b57}\u{8282}\u{6570}\u{7ec4} \u{5199}\u{533a}[8]\n",
        "\u{5199}\u{533a}[0] = 65\n",
        "\u{6574}\u{6570} \u{5199}\u{957f} = \u{6587}\u{4ef6}\u{5199}\u{5165}(\"build\\\\io.bin\", \u{5199}\u{533a}, 1)\n",
        "\u{5b57}\u{8282}\u{6570}\u{7ec4} \u{8bfb}\u{533a}[8]\n",
        "\u{6574}\u{6570} \u{8bfb}\u{957f} = \u{6587}\u{4ef6}\u{8bfb}\u{53d6}(\"build\\\\io.bin\", \u{8bfb}\u{533a}, 8)\n",
        "\u{8f93}\u{51fa}(\u{8bfb}\u{533a}[0])\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    assert!(c.contains("static int64_t bz_read("));
    assert!(c.contains("static int64_t bz_write("));
    assert!(c.contains("fread("));
    assert!(c.contains("fwrite("));
}
#[test]
fn top_level_byte_arrays_are_shared_with_functions() {
    let src = concat!(
        "\u{5b57}\u{8282}\u{6570}\u{7ec4} \u{5171}\u{4eab}[8]\n",
        "\u{51fd}\u{6570} \u{5b58}\u{5165}(\u{503c}) {\n",
        "\u{5171}\u{4eab}[0] = \u{503c}\n\u{8fd4}\u{56de} \u{5171}\u{4eab}[0]\n}\n",
        "\u{8f93}\u{51fa}(\u{5b58}\u{5165}(65))\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    let global = c.find("static unsigned char v_").expect("global buffer");
    let function = c.find("static int64_t v_").expect("function");
    let main = c.find("int main(").expect("main");
    assert!(global < function && function < main, "{c}");
    assert!(!c[main..].contains("unsigned char v_"), "{c}");
}
#[test]
fn command_line_argument_apis_are_emitted_as_generic_runtime_helpers() {
    let src = concat!(
        "\u{6574}\u{6570} \u{6570}\u{91cf} = \u{53c2}\u{6570}\u{6570}\u{91cf}()\n",
        "\u{5b57}\u{8282}\u{6570}\u{7ec4} \u{53c2}\u{6570}[64]\n",
        "\u{6574}\u{6570} \u{957f}\u{5ea6} = \u{53c2}\u{6570}\u{8bfb}\u{53d6}(0, \u{53c2}\u{6570}, 64)\n",
        "\u{8f93}\u{51fa}(\u{6570}\u{91cf} + \u{957f}\u{5ea6})\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    assert!(c.contains("bz_arg_count(void)"));
    assert!(c.contains("bz_arg_read("));
    assert!(c.contains("int main(int argc, char **argv)"));
}
#[test]
fn top_level_integer_state_is_shared_with_functions() {
    let src = concat!(
        "\u{6574}\u{6570} \u{7d22} = 0\n",
        "\u{51fd}\u{6570} \u{589e}\u{52a0}(\u{503c}) {\n",
        "\u{7d22} = \u{7d22} + \u{503c}\n",
        "\u{8fd4}\u{56de} \u{7d22}\n}\n",
        "\u{8f93}\u{51fa}(\u{589e}\u{52a0}(7))\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    let global = c.find("static int64_t v_").expect("global integer");
    let function = c[global + "static int64_t v_".len()..]
        .find("static int64_t v_")
        .map(|i| i + global + "static int64_t v_".len())
        .expect("function");
    let main = c.find("int main(").expect("main");
    assert!(global < function && function < main, "{c}");
    assert!(!c[main..].contains("int64_t v_"), "{c}");
}
#[test]
fn function_local_declarations_remain_local_and_compile() {
    let src = concat!(
        "\u{51fd}\u{6570} \u{8ba1}\u{7b97}(\u{8f93}\u{5165}) {\n",
        "\u{6574}\u{6570} \u{672c}\u{5730} = \u{8f93}\u{5165} + 1\n",
        "\u{5b57}\u{8282}\u{6570}\u{7ec4} \u{7f13}\u{51b2}[8]\n",
        "\u{7f13}\u{51b2}[0] = \u{672c}\u{5730}\n",
        "\u{8fd4}\u{56de} \u{7f13}\u{51b2}[0]\n}\n",
        "\u{8f93}\u{51fa}(\u{8ba1}\u{7b97}(4))\n"
    );
    let (ok, c) = run(src);
    assert!(ok, "{c}");
    let body = c.find("static int64_t v_").unwrap();
    assert!(c[body..].contains("int64_t v_"), "{c}");
    assert!(c[body..].contains("unsigned char v_"), "{c}");
}
