from django.contrib.auth import authenticate
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.tokens import RefreshToken

# Cookie lifetimes mirror SIMPLE_JWT settings in settings.py.
# max_age is in seconds and controls when the browser discards the cookie.
ACCESS_MAX_AGE  = 60 * 60 * 24      # 1 day
REFRESH_MAX_AGE = 60 * 60 * 24 * 7  # 7 days


class LoginView(APIView):
    """
    POST /api/auth/login/
    Body: { "username": "...", "password": "..." }

    On success, sets two HttpOnly cookies and returns 200:
      - access_token  (1 day)
      - refresh_token (7 days)

    HttpOnly means JavaScript can never read these tokens —
    they are invisible to the frontend and immune to XSS theft.
    The browser sends them automatically on every subsequent request.
    """

    permission_classes = [AllowAny]

    def post(self, request):
        username = request.data.get('username')
        password = request.data.get('password')

        if not username or not password:
            return Response(
                {'error': 'username and password are required'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        user = authenticate(request, username=username, password=password)
        if user is None:
            return Response(
                {'error': 'Invalid credentials'},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        refresh = RefreshToken.for_user(user)

        response = Response({'message': 'Login successful'})
        _set_auth_cookies(response, str(refresh.access_token), str(refresh))
        return response


def _set_auth_cookies(response, access_token, refresh_token):
    """Set both auth cookies on a response. Shared by LoginView and RefreshView."""
    cookie_kwargs = dict(
        httponly=True,
        secure=True,    # Only sent over HTTPS (our CloudFront → browser leg)
        samesite='Lax', # Blocks cross-site POST requests (CSRF protection)
    )
    response.set_cookie('access_token',  access_token,  max_age=ACCESS_MAX_AGE,  **cookie_kwargs)
    response.set_cookie('refresh_token', refresh_token, max_age=REFRESH_MAX_AGE, **cookie_kwargs)
