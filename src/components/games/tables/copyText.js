import { toast } from '../../../store/toastStore.js'

/** Copies text, falling back to a toast with the text when the browser won't let the page write to the clipboard. */
export async function copyText(text, what) {
  try {
    await navigator.clipboard.writeText(text)
    toast({ tone: 'success', title: `${what} copied` })
  } catch {
    toast({ tone: 'info', title: `Copy this ${what.toLowerCase()}`, description: text, duration: 12000 })
  }
}
