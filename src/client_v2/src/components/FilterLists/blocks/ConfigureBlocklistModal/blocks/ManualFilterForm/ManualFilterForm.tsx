import { Show, createSignal, createEffect, untrack } from 'solid-js';
import cn from 'clsx';

import intl from 'panel/common/intl';
import { Input } from 'panel/common/controls/Input';
import { validatePath, validateRequiredValue } from 'panel/helpers/validators';
import theme from 'panel/lib/theme';

// Module-level holder for the picked file contents.  The browser cannot know
// real Android filesystem paths, so the file is uploaded by contents and the
// backend stores it under the user filters directory.
let pickedFileContent: string | null = null;
let pickedFileName = '';

export const getPickedFile = () => ({ content: pickedFileContent, name: pickedFileName });
export const clearPickedFile = () => {
    pickedFileContent = null;
    pickedFileName = '';
};

type Props = {
    class?: string;
    initialName?: string;
    initialUrl?: string;
    showFilePicker?: boolean;
};

export const ManualFilterForm = (props: Props) => {
    const [name, setName] = createSignal(untrack(() => props.initialName) ?? '');
    const [url, setUrl] = createSignal(untrack(() => props.initialUrl) ?? '');
    const [urlError, setUrlError] = createSignal<string | undefined>();
    const [fileLabel, setFileLabel] = createSignal('');

    createEffect(() => {
        if (props.initialName !== undefined) {
            setName(props.initialName);
        }
        if (props.initialUrl !== undefined) {
            setUrl(props.initialUrl);
        }
    });

    const handleUrlBlur = () => {
        const urlErr = validateRequiredValue(url()) || validatePath(url());
        setUrlError(urlErr || undefined);
    };

    const handleFilePick = async (e: Event) => {
        const input = e.target as HTMLInputElement;
        const file = input.files?.[0];
        // Allow picking the same file again later: reset the input so the
        // change event fires even if the selection is identical.
        input.value = '';
        clearPickedFile();
        setFileLabel('');
        if (!file) {
            return;
        }
        try {
            const text = await file.text();
            pickedFileContent = text;
            pickedFileName = file.name;
            setFileLabel(file.name);
            // Read both fields straight from the DOM.  The inputs commit to
            // signals on the change event, so a name the user has just typed
            // may not have reached the signal yet; using the signal here would
            // silently overwrite the typed name with the file name.
            const nameEl = document.getElementById('filters_name') as HTMLInputElement | null;
            const urlEl = document.getElementById('filters_url') as HTMLInputElement | null;
            const typedName = (nameEl?.value ?? name()).trim();
            const typedUrl = (urlEl?.value ?? url()).trim();

            // Prefill the name from the file name (without extension) only when
            // the field is empty; keep whatever the user typed otherwise.
            if (!typedName) {
                const base = file.name.replace(/\.[^.]*$/, '');
                setName(base);
            } else if (typedName !== name()) {
                setName(typedName);
            }
            // Prefill URL field with the file name so the existing required
            // validation passes; the modal submit ignores it for uploads.
            if (!typedUrl) {
                setUrl(file.name);
            } else if (typedUrl !== url()) {
                setUrl(typedUrl);
            }
            setUrlError(undefined);
        } catch {
            setUrlError(intl.getMessage('form_error_url_format'));
        }
    };

    return (
        <div class={cn(theme.form.group, props.class)}>
            <div class={theme.form.input}>
                <Input
                    type="text"
                    id="filters_name"
                    name="name"
                    label={intl.getMessage('name_label')}
                    placeholder={intl.getMessage('blocklist_placeholder_example')}
                    value={name()}
                    onChange={(e) => setName((e.target as HTMLInputElement).value)}
                    onCard
                />
            </div>

            <div class={theme.form.input}>
                <Input
                    type="text"
                    id="filters_url"
                    name="url"
                    label={intl.getMessage('blocklist_url_file_path')}
                    placeholder={intl.getMessage('blocklist_url_file_path')}
                    value={url()}
                    onChange={(e) => setUrl((e.target as HTMLInputElement).value)}
                    onBlur={handleUrlBlur}
                    errorMessage={urlError()}
                    onCard
                />
            </div>

            <Show when={props.showFilePicker !== false}>
                <div class={theme.form.input}>
                    <label class="form__label" for="filters_file">
                        {intl.getMessage('filter_add_file_label')}
                    </label>
                    <input
                        type="file"
                        id="filters_file"
                        name="file"
                        accept=".txt,.conf,.hosts,.list,text/plain"
                        onChange={handleFilePick}
                    />
                    <Show when={fileLabel()}>
                        <div>{fileLabel()}</div>
                    </Show>
                </div>
            </Show>
        </div>
    );
};
