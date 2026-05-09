// Copyright 2026 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use std::path::{Path, PathBuf};

const OUTPUT_BASE_SENTINEL: &str = "DO_NOT_BUILD_HERE";

pub(crate) fn find_output_base(start: &Path) -> Option<PathBuf> {
    start
        .ancestors()
        .find(|path| path.join(OUTPUT_BASE_SENTINEL).is_file())
        .map(Path::to_path_buf)
}
