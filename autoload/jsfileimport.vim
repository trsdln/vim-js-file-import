function! jsfileimport#word(is_visual_mode, ...) abort
  call s:do_import('jsfileimport#tags#_get_tag', a:is_visual_mode, a:0)
  let l:repeatMapping = a:0 > 0 ? 'JsFileImportList' : 'JsFileImport'
  silent! call repeat#set("\<Plug>(".l:repeatMapping.')')
endfunction

function! jsfileimport#prompt() abort
  call s:do_import('jsfileimport#tags#_get_tag_data_from_prompt', 0, 0)
  silent! call repeat#set("\<Plug>(PromptJsFileImport)")
endfunction

function! jsfileimport#sort(...) abort
  call jsfileimport#utils#_save_cursor_position('sort')

  let l:rgx = jsfileimport#utils#_determine_import_type()

  if search(l:rgx['select_for_sort'], 'be') > 0
    silent! exe g:js_file_import_sort_command
  endif

  call jsfileimport#utils#_restore_cursor_position('sort')
  return 1
endfunction

function! jsfileimport#goto(is_visual_mode, ...) abort
  try
    call jsfileimport#utils#_check_python_support()
    let l:name = jsfileimport#utils#_get_word(a:is_visual_mode)
    let l:rgx = jsfileimport#utils#_determine_import_type()
    let l:tags = jsfileimport#tags#_get_taglist(l:name, l:rgx)
    let l:current_file_path = expand('%:p')
    let l:show_list = a:0 > 0

    if len(l:tags) == 0
      throw 'Tag not found.'
    endif

    if !l:show_list
      if len(l:tags) == 1
        return jsfileimport#tags#_jump_to_tag(l:tags[0], l:current_file_path, l:show_list)
      endif

      let l:tag_in_current_file = jsfileimport#tags#_get_tag_in_current_file(l:tags, l:current_file_path)

      if l:tag_in_current_file['filename'] !=? ''
        return jsfileimport#tags#_jump_to_tag(l:tag_in_current_file, l:current_file_path, l:show_list)
      endif
    endif

    let l:tag_selection_list = jsfileimport#tags#_generate_tags_selection_list(l:tags)
    let l:options = extend(['Current path: '.expand('%'), 'Select definition:'], l:tag_selection_list)

    call inputsave()
    let l:selection = inputlist(l:options)
    call inputrestore()

    if l:selection < 1
      return 0
    endif

    if l:selection >= len(l:options) - 1
      throw 'Wrong selection.'
    endif

    return jsfileimport#tags#_jump_to_tag(l:tags[l:selection - 1], l:current_file_path, l:show_list)
  catch /.*/
    if v:exception !=? ''
      return jsfileimport#utils#_error(v:exception)
    endif
    return 0
  endtry
endfunction

function! jsfileimport#findusage(is_visual_mode) abort
  try
    if !executable('rg') && !executable('ag')
      throw 'rg (ripgrep) or ag (silversearcher) needed.'
    endif
    let l:rgx = jsfileimport#utils#_determine_import_type()
    let l:word = jsfileimport#utils#_get_word(a:is_visual_mode)
    let l:current_file_path = expand('%')
    let l:executable = executable('rg') ? 'rg --sort-files' : 'ag'
    let l:line = line('.')

    let l:files = jsfileimport#utils#systemlist(l:executable.' '.l:word.' --vimgrep .')
    " Remove current line from list
    call filter(l:files, {idx, val -> val !~ '^'.l:current_file_path.':'.l:line.'.*$'})

    if len(l:files) > 30
      let l:files = jsfileimport#utils#_remove_duplicate_files(l:files)
    endif
    let l:options = []
    for l:file in l:files
      let [l:filename, l:row, l:col, l:pattern] = matchlist(l:file, '\([^:]*\):\(\d*\):\(\d*\):\(.*\)')[1:4]
      call add(l:options, { 'filename': l:filename, 'lnum': l:row, 'col': l:col, 'text': l:pattern })
    endfor

    call setqflist(l:options)
    silent! exe 'copen'
    silent! call repeat#set("\<Plug>(JsFindUsage)")
    return 1
  catch /.*/
    if v:exception !=? ''
      return jsfileimport#utils#_error(v:exception)
    endif
    return 0
  endtry
endfunction

function! jsfileimport#_import_word(name, tag_fn_name, is_visual_mode, show_list) abort
  call jsfileimport#utils#_save_cursor_position('import')
  try
    call jsfileimport#utils#_check_python_support()
    let l:rgx = jsfileimport#utils#_determine_import_type()
    call jsfileimport#utils#_check_import_exists(a:name, 1)
    let l:tag_data = call(a:tag_fn_name, [a:name, l:rgx, a:show_list])

    return s:import_tag(l:tag_data, a:name, l:rgx)
  catch /.*/
    call jsfileimport#utils#_restore_cursor_position('import')
    if v:exception !=? ''
      return jsfileimport#utils#_error(v:exception)
    endif
    return 0
  endtry
endfunction

function! s:do_import(tag_fn_name, is_visual_mode, show_list) abort "{{{
  let l:name = jsfileimport#utils#_get_word(a:is_visual_mode)

  return jsfileimport#_import_word(l:name, a:tag_fn_name, a:is_visual_mode, a:show_list)
endfunction "}}}

function! s:is_partial_import(tag_data, name, rgx) "{{{
  if !empty(a:tag_data['global']) && !empty(a:tag_data['global_partial'])
    return 1
  endif
  let l:tag = a:tag_data['tag']
  let l:partial_rgx = substitute(a:rgx['partial_export'], '__FNAME__', a:name, 'g')

  " Method or partial export
  if l:tag['kind'] =~# '\(m\|p\)' || l:tag['cmd'] =~# l:partial_rgx
    return 1
  endif

  if l:tag['cmd'] =~# a:rgx['default_export'].a:name
    return 0
  endif

  " Read file and try finding export in case when tag points to line
  " that is not descriptive enough
  let l:file_path = getcwd().'/'.l:tag['filename']

  if !filereadable(l:file_path)
    return 0
  endif

  if match(join(readfile(l:file_path, '')), l:partial_rgx) > -1
    return 1
  endif

  return 0
endfunction "}}}

function! s:process_import(name, path, rgx, is_global) abort "{{{
  let l:import_rgx = a:rgx['import']
  let l:import_rgx = substitute(l:import_rgx, '__FNAME__', a:name, '')
  let l:import_rgx = substitute(l:import_rgx, '__FPATH__', a:path, '')

  if ! g:js_file_import_omit_semicolon
    let l:import_rgx = l:import_rgx . ';'
  endif

  let l:append_to_start = 0

  if a:is_global && g:js_file_import_package_first
    let l:append_to_start = 1
  endif

  if search(a:rgx['lastimport'], 'be') > 0 && l:append_to_start == 0
    call append(line('.'), l:import_rgx)
  elseif search(a:rgx['lastimport']) > 0
    call append(line('.') - 1, l:import_rgx)
  else
    call append(0, l:import_rgx)
    call append(1, '')
  endif
  return s:finish_import()
endfunction "}}}

function! s:import_tag(tag_data, name, rgx) abort "{{{
  let l:tag = a:tag_data['tag']
  let l:is_global = !empty(a:tag_data['global'])
  let l:is_partial = s:is_partial_import(a:tag_data, a:name, a:rgx)
  let l:path = l:tag['name']
  if !l:is_global
    let l:path = jsfileimport#utils#_get_file_path(l:tag['filename'])
  endif
  let l:current_file_path = jsfileimport#utils#_get_file_path(expand('%:p'))

  if !l:is_global && l:path ==# l:current_file_path
    throw 'Import failed. Selected import is in this file.'
  endif

  let l:escaped_path = escape(l:path, './')

  if l:is_partial == 0
    return s:process_full_import(a:name, a:rgx, l:path, l:is_global)
  endif

  " Check if only full import exists for given path. ES6 allows partial imports alongside full import
  let l:existing_full_path_only = substitute(a:rgx['existing_full_path_only'], '__FPATH__', l:escaped_path, '')

  if a:rgx['type'] ==? 'import' && search(l:existing_full_path_only, 'n') > 0
    call search(l:existing_full_path_only, 'e')
    return s:process_partial_import_alongside_full(a:name)
  endif

  "Partial single line
  let l:existing_path_rgx = substitute(a:rgx['existing_path'], '__FPATH__', l:escaped_path, '')

  if search(l:existing_path_rgx, 'n') <= 0
    return s:process_import('{ '.a:name.' }', l:path, a:rgx, l:is_global)
  endif

  call search(l:existing_path_rgx)
  let l:start_line = line('.')
  call search(l:existing_path_rgx, 'e')
  let l:end_line = line('.')

  if l:end_line > l:start_line
    return s:process_multi_line_partial_import(a:name)
  endif

  return s:process_single_line_partial_import(a:name)
endfunction "}}}

function! s:process_full_import(name, rgx, path, is_global) abort "{{{
  let l:esc_path = escape(a:path, './')
  let l:existing_import_rgx = substitute(a:rgx['existing_path_for_full'], '__FPATH__', l:esc_path, '')

  if a:rgx['type'] ==? 'import' && search(l:existing_import_rgx, 'n') > 0
    call search(l:existing_import_rgx)
    silent! exe ':normal!i'.a:name.', '
    return s:finish_import()
  endif

  return s:process_import(a:name, a:path, a:rgx, a:is_global)
endfunction "}}}

function! s:process_single_line_partial_import(name) abort "{{{
  let l:char_under_cursor = getline('.')[col('.') - 1]
  let l:first_char = l:char_under_cursor ==? ',' ? ' ' : ', '
  let l:last_char = l:char_under_cursor ==? ',' ? ',' : ''

  silent! exe ':normal!a'.l:first_char.a:name.last_char

  return s:finish_import()
endfunction "}}}

function! s:process_multi_line_partial_import(name) abort "{{{
  let l:char_under_cursor = getline('.')[col('.') - 1]
  let l:first_char = l:char_under_cursor !=? ',' ? ',': ''
  let l:last_char = l:char_under_cursor ==? ',' ? ',' : ''

  silent! exe ':normal!a'.l:first_char
  silent! exe ':normal!o'.a:name.l:last_char

  return s:finish_import()
endfunction "}}}

function! s:process_partial_import_alongside_full(name) abort "{{{
  silent! exe ':normal!a, { '.a:name.' }'

  return s:finish_import()
endfunction "}}}

function! s:finish_import() abort "{{{
  if g:js_file_import_sort_after_insert > 0
    call jsfileimport#sort()
  endif

  call jsfileimport#utils#_restore_cursor_position('import')
  return 1
endfunction "}}}

" vim:foldenable:foldmethod=marker:sw=2
