import streamlit as st
import os

st.set_page_config(page_title="WTW ACA Proxy Debug", layout="wide")

st.title("App Gateway -> APIM -> ACA (Streamlit)")
st.caption("Minimal app to validate the routing chain and inspect proxy / Easy Auth headers.")

# Streamlit does not expose request headers directly in the script context.
# We surface what the platform injects via st.context.headers (Streamlit >= 1.37).
st.subheader("Request headers seen by the app")
try:
    headers = dict(st.context.headers)
    interesting = [
        "host",
        "x-forwarded-host",
        "x-forwarded-proto",
        "x-forwarded-for",
        "x-original-host",
        "x-ms-client-principal-name",
        "x-ms-client-principal-id",
        "x-appgw-trace-id",
    ]
    st.json({k: headers.get(k) for k in interesting})
    with st.expander("All headers"):
        st.json(headers)
except Exception as e:
    st.warning(f"Header introspection not available: {e}")

st.subheader("Environment")
st.write({
    "CONTAINER_APP_NAME": os.environ.get("CONTAINER_APP_NAME"),
    "CONTAINER_APP_REVISION": os.environ.get("CONTAINER_APP_REVISION"),
})

st.success("If you can read this through the WAF, App Gateway -> APIM -> ACA routing works.")
