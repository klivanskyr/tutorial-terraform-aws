from rest_framework_simplejwt.authentication import JWTAuthentication


class CookieJWTAuthentication(JWTAuthentication):
    """
    Reads the JWT access token from an HttpOnly cookie instead of the
    Authorization header. This prevents JavaScript from ever touching the
    token, eliminating the XSS token-theft attack vector.

    The browser automatically includes the cookie on every same-origin
    request, so the frontend needs zero token-handling logic.
    """

    def authenticate(self, request):
        raw_token = request.COOKIES.get('access_token')
        if raw_token is None:
            return None  # No cookie → anonymous request, let permission class decide

        validated_token = self.get_validated_token(raw_token)
        return self.get_user(validated_token), validated_token
