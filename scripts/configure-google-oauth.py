#!/usr/bin/env python3
"""Set public native OAuth client IDs, never client secrets or user tokens."""
import argparse
import pathlib
import re


def configure(source: str, platform: str, client_id: str) -> str:
    if not re.fullmatch(r"[0-9]+-[a-z0-9-]+\.apps\.googleusercontent\.com", client_id):
        raise ValueError("Expected a public Google native OAuth client ID, not a secret or token")
    for key, value in [("CLIENT_ID", client_id), ("CALLBACK_SCHEME", ".".join(reversed(client_id.split("."))))]:
        pattern = rf'(?m)^    TURING_GOOGLE_{platform}_{key}: .*?$'
        source, count = re.subn(pattern, f'    TURING_GOOGLE_{platform}_{key}: "{value}"', source)
        if count != 1:
            raise ValueError(f"Missing or ambiguous {platform} {key} setting")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios-client-id")
    parser.add_argument("--macos-client-id")
    args = parser.parse_args()
    if not args.ios_client_id and not args.macos_client_id:
        parser.error("Provide at least one native OAuth client ID")
    path = pathlib.Path(__file__).resolve().parents[1] / "project.yml"
    source = path.read_text()
    try:
        for platform, client_id in [("IOS", args.ios_client_id), ("MACOS", args.macos_client_id)]:
            if client_id:
                source = configure(source, platform, client_id)
    except ValueError as error:
        parser.error(str(error))
    path.write_text(source)
    print("Public OAuth configuration updated. Run xcodegen generate, rebuild, and test sign-in.")


if __name__ == "__main__":
    main()
