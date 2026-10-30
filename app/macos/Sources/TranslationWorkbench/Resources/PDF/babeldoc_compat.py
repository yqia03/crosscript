"""Narrow compatibility repairs for the exact pinned BabelDOC release.

Upstream 0.6.4's watermark-both branch calls the misspelled method
`typsetting_document` while the Typesetting class only exposes
`typesetting_document`. The upstream exception handler silently drops one
output variant. Alias only that call; keep the original engine implementation.
"""
import importlib.metadata


def install():
    if importlib.metadata.version('babeldoc') != '0.6.4':
        raise ValueError('compatibility adapter requires BabelDOC 0.6.4')
    from babeldoc.format.pdf.document_il.midend.typesetting import Typesetting
    if not hasattr(Typesetting, 'typsetting_document'):
        Typesetting.typsetting_document = Typesetting.typesetting_document


def preserve_first_output_watermark(config):
    """0.6.4 uses split index, which loses watermarks when early parts are excluded.

    Each bridge process runs exactly one job. Set the original mode on the first
    part that actually produces output; leave subsequent parts without watermarks.
    """
    from babeldoc.format.pdf import high_level
    original = high_level._do_translate_single
    watermark_mode = config.watermark_output_mode
    first_output = True

    def translate_part(monitor, part_config):
        nonlocal first_output
        if first_output:
            part_config.watermark_output_mode = watermark_mode
            first_output = False
        return original(monitor, part_config)

    high_level._do_translate_single = translate_part
